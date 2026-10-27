-- pg-email-dispatcher: tables.
--
-- The database is the contract. Every lifecycle decision (who may send, when,
-- to whom, and what happened) is recorded here; the worker only spends tokens
-- that Postgres has already issued. All tables are service-role only: RLS is
-- enabled with no policies, and anon/authenticated grants are revoked.

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  new.updated_at := now();
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION public.normalize_email(input text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path = public
AS $$
  SELECT lower(btrim(input));
$$;

-- ── Senders ────────────────────────────────────────────────────────────────
-- A sender is the identity a campaign is sent as. Its connected provider
-- mailbox lives in sender_credentials; the reputation scope is derived from
-- that mailbox, not from this row's email.

CREATE TABLE public.senders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL CHECK (length(btrim(email)) > 0),
  display_name text NULL,
  disabled_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_senders_updated_at
  BEFORE UPDATE ON public.senders
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ── Contacts and campaigns ─────────────────────────────────────────────────

CREATE TABLE public.contacts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL CHECK (length(btrim(email)) > 0),
  normalized_email text GENERATED ALWAYS AS (public.normalize_email(email)) STORED,
  first_name text NULL,
  last_name text NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT contacts_normalized_email_key UNIQUE (normalized_email)
);

CREATE TRIGGER trg_contacts_updated_at
  BEFORE UPDATE ON public.contacts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TYPE public.campaign_pause_reason AS ENUM (
  'user_paused',
  'sender_oauth_revoked',
  'dispatcher_error'
);

CREATE TABLE public.campaigns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id uuid NOT NULL REFERENCES public.senders (id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (length(btrim(name)) > 0),
  subject text NOT NULL CHECK (length(btrim(subject)) > 0),
  preview_text text NULL,
  body_html text NOT NULL DEFAULT '',
  body_text text NULL,
  reply_to_email text NULL,
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'live', 'paused', 'completed', 'canceled')),
  send_at timestamptz NULL,
  started_at timestamptz NULL,
  finished_at timestamptz NULL,
  paused_at timestamptz NULL,
  pause_reason public.campaign_pause_reason NULL,
  canceled_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT campaigns_live_requires_send_at
    CHECK (status <> 'live' OR send_at IS NOT NULL)
);

CREATE INDEX campaigns_due_idx
  ON public.campaigns (send_at, created_at)
  WHERE status = 'live';

CREATE INDEX campaigns_sender_status_idx
  ON public.campaigns (sender_id, status);

CREATE TRIGGER trg_campaigns_updated_at
  BEFORE UPDATE ON public.campaigns
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- campaign_contacts is both explicit campaign membership and the recipient
-- queue item. One row is one email to one contact; attempts are retries of
-- that same email.
CREATE TABLE public.campaign_contacts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL REFERENCES public.campaigns (id) ON DELETE CASCADE,
  contact_id uuid NOT NULL REFERENCES public.contacts (id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN (
      'pending',
      'retry_scheduled',
      'leased',
      'sent',
      'failed',
      'send_unknown',
      'canceled'
    )),
  send_after timestamptz NOT NULL DEFAULT now(),
  next_retry_at timestamptz NULL,
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  last_error text NULL,
  lease_token uuid NULL,
  leased_at timestamptz NULL,
  lease_expires_at timestamptz NULL,
  sent_at timestamptz NULL,
  provider_message_id text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT campaign_contacts_campaign_contact_key UNIQUE (campaign_id, contact_id),
  CONSTRAINT campaign_contacts_leased_has_token
    CHECK (status <> 'leased' OR (lease_token IS NOT NULL AND lease_expires_at IS NOT NULL))
);

CREATE INDEX campaign_contacts_sendable_idx
  ON public.campaign_contacts (
    status,
    (coalesce(next_retry_at, send_after)),
    created_at,
    campaign_id
  )
  WHERE status IN ('pending', 'retry_scheduled');

CREATE INDEX campaign_contacts_campaign_idx
  ON public.campaign_contacts (campaign_id, status, created_at);

CREATE INDEX campaign_contacts_contact_idx
  ON public.campaign_contacts (contact_id);

CREATE INDEX campaign_contacts_lease_expiry_idx
  ON public.campaign_contacts (lease_expires_at)
  WHERE status = 'leased';

CREATE INDEX campaign_contacts_unknown_idx
  ON public.campaign_contacts (campaign_id, updated_at DESC)
  WHERE status = 'send_unknown';

CREATE TRIGGER trg_campaign_contacts_updated_at
  BEFORE UPDATE ON public.campaign_contacts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE FUNCTION public.enforce_live_campaign_has_contacts()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF new.status <> 'live' THEN
    RETURN new;
  END IF;

  IF tg_op = 'UPDATE' AND old.status IS NOT DISTINCT FROM new.status THEN
    RETURN new;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.campaign_contacts cc
    WHERE cc.campaign_id = new.id
      AND cc.status <> 'canceled'
  ) THEN
    RAISE EXCEPTION 'campaign must have at least one sendable contact before going live'
      USING errcode = 'P0001';
  END IF;

  RETURN new;
END;
$$;

CREATE TRIGGER trg_campaigns_live_has_contacts
  BEFORE INSERT OR UPDATE OF status ON public.campaigns
  FOR EACH ROW EXECUTE FUNCTION public.enforce_live_campaign_has_contacts();

-- ── Unsubscribe and suppression ────────────────────────────────────────────
-- Suppression is send eligibility, not contact identity, so it is keyed by
-- normalized email and survives contact deletion.

CREATE TABLE public.suppressions (
  normalized_email text PRIMARY KEY,
  contact_id uuid NULL REFERENCES public.contacts (id) ON DELETE SET NULL,
  suppressed_via text NOT NULL
    CHECK (suppressed_via IN ('unsubscribe_link', 'one_click_header', 'admin_action')),
  suppressed_at timestamptz NOT NULL DEFAULT now()
);

-- Opaque, stable per-address token used in unsubscribe links and the
-- List-Unsubscribe header, so a resend reuses the same link.
CREATE TABLE public.unsubscribe_tokens (
  token uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  normalized_email text NOT NULL UNIQUE,
  contact_id uuid NULL REFERENCES public.contacts (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ── Provider credentials ───────────────────────────────────────────────────
-- Token values live only in Supabase Vault; this table stores Vault secret ids.

CREATE EXTENSION IF NOT EXISTS supabase_vault CASCADE;

CREATE TABLE public.sender_credentials (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id uuid NOT NULL REFERENCES public.senders (id) ON DELETE CASCADE,
  provider text NOT NULL CHECK (provider = 'google'),
  provider_email text NOT NULL CHECK (length(btrim(provider_email)) > 0),
  access_token_secret_id uuid NOT NULL,
  refresh_token_secret_id uuid NULL,
  access_token_expires_at timestamptz NULL,
  scopes text[] NULL,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'reauth_required', 'disabled')),
  last_refresh_at timestamptz NULL,
  reauth_required_at timestamptz NULL,
  last_error text NULL CHECK (last_error IS NULL OR length(last_error) <= 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sender_credentials_sender_provider_key UNIQUE (sender_id, provider)
);

CREATE UNIQUE INDEX sender_credentials_one_active_per_sender_idx
  ON public.sender_credentials (sender_id)
  WHERE status = 'active';

CREATE TRIGGER trg_sender_credentials_updated_at
  BEFORE UPDATE ON public.sender_credentials
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ── Sender reputation (domain protection) ──────────────────────────────────
-- A scope is what mailbox providers judge as one sender: the individual
-- mailbox for consumer domains (gmail.com, outlook.com, ...), or the whole
-- domain for custom domains. Several senders on one custom domain share one
-- scope, so one noisy sender cannot burn the domain for the others.

CREATE TABLE public.sender_reputation_scopes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scope_key text NOT NULL UNIQUE CHECK (length(btrim(scope_key)) > 0),
  scope_key_type text NOT NULL CHECK (scope_key_type IN ('public_mailbox', 'custom_domain')),
  normalized_sender_email text NOT NULL,
  normalized_domain text NOT NULL,
  state text NOT NULL DEFAULT 'warming'
    CHECK (state IN ('warming', 'cooling_down', 'safety_paused')),
  warmup_started_at timestamptz NULL,
  last_token_issued_at timestamptz NULL,
  cooldown_until timestamptz NULL,
  cooldown_reason text NULL,
  safety_paused_at timestamptz NULL,
  safety_pause_reason text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN public.sender_reputation_scopes.warmup_started_at IS
  'Null until the first token is issued for this scope; connecting a mailbox without sending does not burn warmup time.';

CREATE TRIGGER trg_sender_reputation_scopes_updated_at
  BEFORE UPDATE ON public.sender_reputation_scopes
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.sender_reputation_scope_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scope_id uuid NOT NULL REFERENCES public.sender_reputation_scopes (id) ON DELETE CASCADE,
  action text NOT NULL CHECK (length(btrim(action)) > 0),
  actor_email text NOT NULL CHECK (length(btrim(actor_email)) > 0),
  performed_at timestamptz NOT NULL DEFAULT now(),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX sender_reputation_scope_audit_scope_idx
  ON public.sender_reputation_scope_audit (scope_id, performed_at DESC);

-- Why work was deferred during one worker cycle (cap hit, interval, cooldown,
-- safety pause). The worker drains and logs these once per cycle.
CREATE TABLE public.scope_deferral_rollups (
  worker_id uuid NOT NULL,
  scope_id uuid NOT NULL REFERENCES public.sender_reputation_scopes (id) ON DELETE CASCADE,
  scope_key_type text NOT NULL,
  deferral_reason text NOT NULL,
  tier text NOT NULL,
  deferred_count integer NOT NULL DEFAULT 1 CHECK (deferred_count > 0),
  first_deferred_at timestamptz NOT NULL DEFAULT now(),
  last_deferred_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (worker_id, scope_id, deferral_reason, tier)
);

-- ── Token log and attempt ledger ───────────────────────────────────────────
-- A send token is issued at the dangerous boundary: after it exists, the
-- system assumes an external send may happen or may already have happened.
-- send_tokens drives pacing and caps; send_attempts is the per-attempt ledger.

CREATE TABLE public.send_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id uuid NOT NULL REFERENCES public.senders (id) ON DELETE RESTRICT,
  campaign_contact_id uuid NOT NULL REFERENCES public.campaign_contacts (id) ON DELETE RESTRICT,
  lease_token uuid NOT NULL UNIQUE,
  issued_at timestamptz NOT NULL DEFAULT now(),
  reputation_scope_id uuid NULL REFERENCES public.sender_reputation_scopes (id) ON DELETE SET NULL,
  reputation_scope_key text NULL,
  provider_email text NULL
);

CREATE INDEX send_tokens_sender_issued_idx
  ON public.send_tokens (sender_id, issued_at);

CREATE INDEX send_tokens_scope_issued_idx
  ON public.send_tokens (reputation_scope_id, issued_at)
  WHERE reputation_scope_id IS NOT NULL;

CREATE INDEX send_tokens_recipient_idx
  ON public.send_tokens (campaign_contact_id, issued_at DESC);

CREATE TABLE public.send_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL REFERENCES public.campaigns (id) ON DELETE RESTRICT,
  campaign_contact_id uuid NOT NULL REFERENCES public.campaign_contacts (id) ON DELETE RESTRICT,
  sender_id uuid NOT NULL REFERENCES public.senders (id) ON DELETE RESTRICT,
  send_token_id uuid NOT NULL UNIQUE REFERENCES public.send_tokens (id) ON DELETE RESTRICT,
  attempt_no integer NOT NULL CHECK (attempt_no > 0),
  status text NOT NULL DEFAULT 'started'
    CHECK (status IN ('started', 'sent', 'failed', 'retry_scheduled', 'send_unknown')),
  lease_token uuid NOT NULL UNIQUE,
  failure_category text NULL,
  requested_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz NULL,
  provider_message_id text NULL,
  error_message text NULL,
  CONSTRAINT send_attempts_recipient_attempt_key UNIQUE (campaign_contact_id, attempt_no)
);

CREATE INDEX send_attempts_campaign_idx
  ON public.send_attempts (campaign_id, requested_at DESC);

CREATE INDEX send_attempts_unknown_idx
  ON public.send_attempts (requested_at DESC)
  WHERE status = 'send_unknown';

-- ── Access ─────────────────────────────────────────────────────────────────

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'senders', 'contacts', 'campaigns', 'campaign_contacts', 'suppressions',
    'unsubscribe_tokens', 'sender_credentials', 'sender_reputation_scopes',
    'sender_reputation_scope_audit', 'scope_deferral_rollups', 'send_tokens',
    'send_attempts'
  ]
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.%I TO service_role', t);
  END LOOP;
END;
$$;

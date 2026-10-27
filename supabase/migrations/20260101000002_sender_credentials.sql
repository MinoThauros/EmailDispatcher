-- pg-email-dispatcher: sender provider credentials.
--
-- OAuth tokens are stored in Supabase Vault under deterministic names
-- (dispatcher/sender/<sender_id>/<provider>/access_token|refresh_token).
-- Only these SECURITY DEFINER functions read or write them.

-- Every dispatcher RPC is service-role only. EXECUTE is also revoked from
-- anon/authenticated; this check is defense in depth for SECURITY DEFINER
-- bodies. A direct superuser session (migrations, seeds, pgTAP) is allowed.
CREATE OR REPLACE FUNCTION public.dispatcher_require_service_role()
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' AND session_user <> 'postgres' THEN
    RAISE EXCEPTION 'Forbidden: service role required' USING errcode = '42501';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.dispatcher_vault_secret_name(
  p_sender_id uuid,
  p_provider text,
  p_kind text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT 'dispatcher/sender/' || p_sender_id::text || '/' || p_provider || '/' || p_kind;
$$;

-- Creates or rotates the named Vault secret and returns its id. Prefers the id
-- the credential row already points at, then the deterministic name.
CREATE OR REPLACE FUNCTION public.dispatcher_vault_put(
  p_existing_id uuid,
  p_name text,
  p_value text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
BEGIN
  SELECT s.id
    INTO v_id
  FROM vault.secrets s
  WHERE s.id = p_existing_id
     OR s.name = p_name
  ORDER BY (s.id = p_existing_id) DESC NULLS LAST
  LIMIT 1;

  IF v_id IS NULL THEN
    RETURN vault.create_secret(p_value, p_name, 'pg-email-dispatcher sender token');
  END IF;

  PERFORM vault.update_secret(v_id, p_value, p_name, 'pg-email-dispatcher sender token');
  RETURN v_id;
END;
$$;

-- Strips anything that looks like a token before it is stored as last_error.
CREATE OR REPLACE FUNCTION public.dispatcher_redact_error(p_message text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
  v text := coalesce(nullif(btrim(p_message), ''), 'reauth required');
BEGIN
  v := regexp_replace(v, '[[:cntrl:]]+', ' ', 'g');
  v := regexp_replace(
    v,
    '(?i)(authorization[[:space:]]*[:=][[:space:]]*bearer|bearer)[[:space:]]+[^[:space:],;]+',
    '\1 [redacted]',
    'g'
  );
  v := regexp_replace(
    v,
    '(?i)(access_token|refresh_token|id_token|client_secret)([[:space:]]*[:=][[:space:]]*)[^[:space:],;]+',
    '\1\2[redacted]',
    'g'
  );
  v := regexp_replace(v, '[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '[redacted-jwt]', 'g');
  v := regexp_replace(v, '[A-Za-z0-9_-]{32,}', '[redacted-token]', 'g');
  RETURN left(v, 500);
END;
$$;

-- Called by your OAuth callback after the sender connects a mailbox.
CREATE OR REPLACE FUNCTION public.dispatcher_upsert_sender_credentials(
  p_sender_id uuid,
  p_provider text,
  p_provider_email text,
  p_access_token text,
  p_refresh_token text DEFAULT NULL,
  p_access_token_expires_at timestamptz DEFAULT NULL,
  p_scopes text[] DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_provider text := lower(btrim(p_provider));
  v_provider_email text := public.normalize_email(p_provider_email);
  v_existing record;
  v_access_secret_id uuid;
  v_refresh_secret_id uuid;
BEGIN
  PERFORM public.dispatcher_require_service_role();

  IF p_sender_id IS NULL THEN
    RAISE EXCEPTION 'sender_id is required';
  END IF;

  IF v_provider IS DISTINCT FROM 'google' THEN
    RAISE EXCEPTION 'unsupported sender provider: %', p_provider;
  END IF;

  IF v_provider_email IS NULL OR v_provider_email = '' THEN
    RAISE EXCEPTION 'provider_email is required';
  END IF;

  IF p_access_token IS NULL OR btrim(p_access_token) = '' THEN
    RAISE EXCEPTION 'access_token is required';
  END IF;

  SELECT sc.access_token_secret_id, sc.refresh_token_secret_id
    INTO v_existing
  FROM public.sender_credentials sc
  WHERE sc.sender_id = p_sender_id
    AND sc.provider = v_provider
  FOR UPDATE;

  v_access_secret_id := public.dispatcher_vault_put(
    v_existing.access_token_secret_id,
    public.dispatcher_vault_secret_name(p_sender_id, v_provider, 'access_token'),
    p_access_token
  );

  -- OAuth responses do not always include a refresh token; keep the old one.
  IF p_refresh_token IS NOT NULL AND btrim(p_refresh_token) <> '' THEN
    v_refresh_secret_id := public.dispatcher_vault_put(
      v_existing.refresh_token_secret_id,
      public.dispatcher_vault_secret_name(p_sender_id, v_provider, 'refresh_token'),
      p_refresh_token
    );
  ELSE
    v_refresh_secret_id := v_existing.refresh_token_secret_id;
  END IF;

  INSERT INTO public.sender_credentials (
    sender_id,
    provider,
    provider_email,
    access_token_secret_id,
    refresh_token_secret_id,
    access_token_expires_at,
    scopes,
    status
  )
  VALUES (
    p_sender_id,
    v_provider,
    v_provider_email,
    v_access_secret_id,
    v_refresh_secret_id,
    p_access_token_expires_at,
    p_scopes,
    'active'
  )
  ON CONFLICT (sender_id, provider) DO UPDATE
  SET
    provider_email = excluded.provider_email,
    access_token_secret_id = excluded.access_token_secret_id,
    refresh_token_secret_id = excluded.refresh_token_secret_id,
    access_token_expires_at = excluded.access_token_expires_at,
    scopes = excluded.scopes,
    status = 'active',
    reauth_required_at = NULL,
    last_error = NULL;
END;
$$;

-- Returns decrypted tokens only while the credential is active. Locks the row
-- so a concurrent refresh in another worker serializes behind this read.
CREATE OR REPLACE FUNCTION public.dispatcher_resolve_sender_credentials(
  p_sender_id uuid
)
RETURNS TABLE (
  sender_id uuid,
  provider text,
  provider_email text,
  access_token text,
  refresh_token text,
  access_token_expires_at timestamptz,
  status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.dispatcher_require_service_role();

  RETURN QUERY
  SELECT
    sc.sender_id,
    sc.provider,
    sc.provider_email,
    CASE WHEN sc.status = 'active' THEN access_secret.decrypted_secret END,
    CASE WHEN sc.status = 'active' THEN refresh_secret.decrypted_secret END,
    sc.access_token_expires_at,
    sc.status
  FROM public.sender_credentials sc
  LEFT JOIN vault.decrypted_secrets access_secret
    ON access_secret.id = sc.access_token_secret_id
  LEFT JOIN vault.decrypted_secrets refresh_secret
    ON refresh_secret.id = sc.refresh_token_secret_id
  WHERE sc.sender_id = p_sender_id
    AND sc.provider = 'google'
  LIMIT 1
  FOR UPDATE OF sc;
END;
$$;

CREATE OR REPLACE FUNCTION public.dispatcher_store_refreshed_access_token(
  p_sender_id uuid,
  p_provider text,
  p_access_token text,
  p_access_token_expires_at timestamptz DEFAULT NULL,
  p_refresh_token text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_provider text := lower(btrim(p_provider));
  v_existing record;
  v_access_secret_id uuid;
  v_refresh_secret_id uuid;
BEGIN
  PERFORM public.dispatcher_require_service_role();

  IF p_access_token IS NULL OR btrim(p_access_token) = '' THEN
    RAISE EXCEPTION 'access_token is required';
  END IF;

  SELECT sc.access_token_secret_id, sc.refresh_token_secret_id
    INTO v_existing
  FROM public.sender_credentials sc
  WHERE sc.sender_id = p_sender_id
    AND sc.provider = v_provider
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sender credentials not found';
  END IF;

  v_access_secret_id := public.dispatcher_vault_put(
    v_existing.access_token_secret_id,
    public.dispatcher_vault_secret_name(p_sender_id, v_provider, 'access_token'),
    p_access_token
  );

  v_refresh_secret_id := v_existing.refresh_token_secret_id;

  IF p_refresh_token IS NOT NULL AND btrim(p_refresh_token) <> '' THEN
    v_refresh_secret_id := public.dispatcher_vault_put(
      v_existing.refresh_token_secret_id,
      public.dispatcher_vault_secret_name(p_sender_id, v_provider, 'refresh_token'),
      p_refresh_token
    );
  END IF;

  UPDATE public.sender_credentials sc
  SET
    access_token_secret_id = v_access_secret_id,
    refresh_token_secret_id = v_refresh_secret_id,
    access_token_expires_at = p_access_token_expires_at,
    status = 'active',
    last_refresh_at = now(),
    reauth_required_at = NULL,
    last_error = NULL
  WHERE sc.sender_id = p_sender_id
    AND sc.provider = v_provider;
END;
$$;

CREATE OR REPLACE FUNCTION public.dispatcher_mark_sender_reauth_required(
  p_sender_id uuid,
  p_provider text,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.dispatcher_require_service_role();

  UPDATE public.sender_credentials sc
  SET
    status = 'reauth_required',
    reauth_required_at = now(),
    last_error = public.dispatcher_redact_error(p_reason)
  WHERE sc.sender_id = p_sender_id
    AND sc.provider = lower(btrim(p_provider));

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sender credentials not found';
  END IF;
END;
$$;

-- Purges stored tokens and parks the credential as reauth_required (the row is
-- kept so a UI can offer "reconnect"). Pauses the sender's live campaigns
-- explicitly, because the auto-pause trigger below only fires on the
-- active -> reauth_required transition. Idempotent.
CREATE OR REPLACE FUNCTION public.dispatcher_disconnect_sender(
  p_sender_id uuid,
  p_provider text DEFAULT 'google'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_provider text := lower(btrim(p_provider));
  v_existing record;
BEGIN
  PERFORM public.dispatcher_require_service_role();

  SELECT sc.access_token_secret_id, sc.refresh_token_secret_id
    INTO v_existing
  FROM public.sender_credentials sc
  WHERE sc.sender_id = p_sender_id
    AND sc.provider = v_provider
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  DELETE FROM vault.secrets
  WHERE id IN (v_existing.access_token_secret_id, v_existing.refresh_token_secret_id)
     OR name IN (
       public.dispatcher_vault_secret_name(p_sender_id, v_provider, 'access_token'),
       public.dispatcher_vault_secret_name(p_sender_id, v_provider, 'refresh_token')
     );

  UPDATE public.sender_credentials sc
  SET
    status = 'reauth_required',
    reauth_required_at = now(),
    last_error = 'disconnected by admin'
  WHERE sc.sender_id = p_sender_id
    AND sc.provider = v_provider;

  UPDATE public.campaigns
  SET
    status = 'paused',
    pause_reason = 'sender_oauth_revoked',
    paused_at = now()
  WHERE sender_id = p_sender_id
    AND status = 'live';

  RETURN true;
END;
$$;

-- When a sender's credential stops working, stop their live campaigns. There
-- is deliberately no auto-resume: a person decides when to send again.
CREATE OR REPLACE FUNCTION public.dispatcher_pause_campaigns_on_credential_loss()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.campaigns
  SET
    status = 'paused',
    pause_reason = 'sender_oauth_revoked',
    paused_at = now()
  WHERE sender_id = new.sender_id
    AND status = 'live';

  RETURN new;
END;
$$;

CREATE TRIGGER trg_pause_campaigns_on_credential_loss
  AFTER UPDATE OF status ON public.sender_credentials
  FOR EACH ROW
  WHEN (old.status = 'active' AND new.status <> 'active')
  EXECUTE FUNCTION public.dispatcher_pause_campaigns_on_credential_loss();

REVOKE ALL ON FUNCTION public.dispatcher_require_service_role() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_vault_put(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.dispatcher_upsert_sender_credentials(uuid, text, text, text, text, timestamptz, text[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_resolve_sender_credentials(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_store_refreshed_access_token(uuid, text, text, timestamptz, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_mark_sender_reauth_required(uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_disconnect_sender(uuid, text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.dispatcher_require_service_role() TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_upsert_sender_credentials(uuid, text, text, text, text, timestamptz, text[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_resolve_sender_credentials(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_store_refreshed_access_token(uuid, text, text, timestamptz, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_mark_sender_reauth_required(uuid, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_disconnect_sender(uuid, text) TO service_role;

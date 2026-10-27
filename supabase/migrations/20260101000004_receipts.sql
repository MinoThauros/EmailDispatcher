-- pg-email-dispatcher: receipts, unknown recovery, and campaign completion.
--
-- A receipt is the provider's answer handed back to Postgres. Every receipt
-- must present the lease token that was issued; a stale or replayed receipt
-- is rejected instead of moving the wrong recipient.
--
-- Unknown beats duplicate: if the worker cannot prove what the provider did
-- (timeout, 5xx, crash before the receipt), the recipient becomes
-- send_unknown and is never retried automatically. A late receipt carrying
-- the same lease token can still resolve it to sent or failed.

-- Retryable failures become terminal on this attempt.
CREATE OR REPLACE FUNCTION public.dispatcher_max_attempts()
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 5;
$$;

-- Locks the recipient and checks the lease token. Shared by every receipt.
CREATE OR REPLACE FUNCTION public.dispatcher_lock_receipt_recipient(
  p_campaign_contact_id uuid,
  p_lease_token uuid,
  p_allowed_statuses text[]
)
RETURNS public.campaign_contacts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.campaign_contacts;
BEGIN
  SELECT * INTO v_row
  FROM public.campaign_contacts cc
  WHERE cc.id = p_campaign_contact_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign contact not found';
  END IF;

  IF v_row.lease_token IS DISTINCT FROM p_lease_token THEN
    RAISE EXCEPTION 'stale or invalid send lease token';
  END IF;

  IF NOT (v_row.status = ANY (p_allowed_statuses)) THEN
    RAISE EXCEPTION 'campaign contact is not awaiting this receipt (status=%)', v_row.status;
  END IF;

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.dispatcher_receipt_sent(
  p_campaign_contact_id uuid,
  p_lease_token uuid,
  p_provider_message_id text DEFAULT NULL,
  p_completed_at timestamptz DEFAULT now()
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_completed_at timestamptz := coalesce(p_completed_at, now());
  v_updated integer;
BEGIN
  PERFORM public.dispatcher_require_service_role();
  PERFORM public.dispatcher_lock_receipt_recipient(
    p_campaign_contact_id, p_lease_token, ARRAY['leased', 'send_unknown']
  );

  UPDATE public.campaign_contacts cc
  SET
    status = 'sent',
    sent_at = v_completed_at,
    provider_message_id = p_provider_message_id,
    next_retry_at = NULL,
    last_error = NULL,
    lease_token = NULL,
    leased_at = NULL,
    lease_expires_at = NULL
  WHERE cc.id = p_campaign_contact_id;

  UPDATE public.send_attempts a
  SET
    status = 'sent',
    completed_at = v_completed_at,
    provider_message_id = p_provider_message_id,
    error_message = NULL
  WHERE a.lease_token = p_lease_token;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'attempt ledger row not found for lease token';
  END IF;
END;
$$;

-- The lease token stays on the row so a late receipt can still resolve it.
CREATE OR REPLACE FUNCTION public.dispatcher_receipt_unknown(
  p_campaign_contact_id uuid,
  p_lease_token uuid,
  p_error_message text,
  p_completed_at timestamptz DEFAULT now()
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_completed_at timestamptz := coalesce(p_completed_at, now());
  v_error text := coalesce(nullif(btrim(p_error_message), ''), 'send outcome unknown');
  v_updated integer;
BEGIN
  PERFORM public.dispatcher_require_service_role();
  PERFORM public.dispatcher_lock_receipt_recipient(
    p_campaign_contact_id, p_lease_token, ARRAY['leased']
  );

  UPDATE public.campaign_contacts cc
  SET
    status = 'send_unknown',
    last_error = v_error,
    sent_at = NULL,
    provider_message_id = NULL
  WHERE cc.id = p_campaign_contact_id;

  UPDATE public.send_attempts a
  SET
    status = 'send_unknown',
    completed_at = v_completed_at,
    provider_message_id = NULL,
    error_message = v_error
  WHERE a.lease_token = p_lease_token;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'attempt ledger row not found for lease token';
  END IF;
END;
$$;

-- p_retry_after NULL means a definite failure. A retryable failure on the
-- last allowed attempt is also terminal. An operator_action failure (the
-- provider says a human must fix something, e.g. the API is disabled)
-- safety-pauses the whole reputation scope.
CREATE OR REPLACE FUNCTION public.dispatcher_receipt_failed(
  p_campaign_contact_id uuid,
  p_lease_token uuid,
  p_error_message text,
  p_retry_after timestamptz DEFAULT NULL,
  p_completed_at timestamptz DEFAULT now(),
  p_failure_category text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_recipient public.campaign_contacts;
  v_completed_at timestamptz := coalesce(p_completed_at, now());
  v_error text := coalesce(nullif(btrim(p_error_message), ''), 'send failed');
  v_category text := nullif(btrim(p_failure_category), '');
  v_status text;
  v_scope_id uuid;
  v_updated integer;
BEGIN
  PERFORM public.dispatcher_require_service_role();
  v_recipient := public.dispatcher_lock_receipt_recipient(
    p_campaign_contact_id, p_lease_token, ARRAY['leased', 'send_unknown']
  );

  SELECT t.reputation_scope_id INTO v_scope_id
  FROM public.send_attempts a
  JOIN public.send_tokens t ON t.id = a.send_token_id
  WHERE a.lease_token = p_lease_token;

  v_status := CASE
    WHEN p_retry_after IS NULL THEN 'failed'
    WHEN v_recipient.attempt_count >= public.dispatcher_max_attempts() THEN 'failed'
    ELSE 'retry_scheduled'
  END;

  UPDATE public.campaign_contacts cc
  SET
    status = v_status,
    next_retry_at = CASE WHEN v_status = 'retry_scheduled' THEN p_retry_after END,
    last_error = v_error,
    sent_at = NULL,
    provider_message_id = NULL,
    lease_token = NULL,
    leased_at = NULL,
    lease_expires_at = NULL
  WHERE cc.id = p_campaign_contact_id;

  UPDATE public.send_attempts a
  SET
    status = v_status,
    completed_at = v_completed_at,
    provider_message_id = NULL,
    failure_category = v_category,
    error_message = v_error
  WHERE a.lease_token = p_lease_token;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'attempt ledger row not found for lease token';
  END IF;

  IF v_category = 'operator_action' AND v_scope_id IS NOT NULL THEN
    UPDATE public.sender_reputation_scopes s
    SET
      state = 'safety_paused',
      safety_paused_at = coalesce(s.safety_paused_at, v_completed_at),
      safety_pause_reason = v_error
    WHERE s.id = v_scope_id;
  END IF;
END;
$$;

-- A worker that crashed or timed out after taking a token never hands back a
-- receipt. Its lease expires and the recipient becomes send_unknown, because
-- the provider may already have delivered the email.
CREATE OR REPLACE FUNCTION public.dispatcher_mark_expired_sends_unknown(
  p_now timestamptz DEFAULT now()
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_now timestamptz := coalesce(p_now, now());
  v_error text := 'send lease expired before receipt; provider outcome unknown';
  v_recipients integer;
  v_attempts integer;
BEGIN
  PERFORM public.dispatcher_require_service_role();

  WITH expired AS (
    SELECT cc.id, cc.lease_token
    FROM public.campaign_contacts cc
    WHERE cc.status = 'leased'
      AND cc.lease_expires_at <= v_now
    FOR UPDATE OF cc SKIP LOCKED
  ),
  updated_recipients AS (
    UPDATE public.campaign_contacts cc
    SET
      status = 'send_unknown',
      last_error = v_error,
      sent_at = NULL,
      provider_message_id = NULL
    FROM expired e
    WHERE cc.id = e.id
    RETURNING cc.lease_token
  ),
  updated_attempts AS (
    UPDATE public.send_attempts a
    SET
      status = 'send_unknown',
      completed_at = v_now,
      provider_message_id = NULL,
      error_message = v_error
    FROM updated_recipients r
    WHERE a.lease_token = r.lease_token
    RETURNING a.id
  )
  SELECT
    (SELECT count(*) FROM updated_recipients)::integer,
    (SELECT count(*) FROM updated_attempts)::integer
    INTO v_recipients, v_attempts;

  IF v_attempts <> v_recipients THEN
    RAISE EXCEPTION 'attempt ledger row not found for expired lease token';
  END IF;

  RETURN v_recipients;
END;
$$;

-- A live campaign completes once nothing is left that could still send.
-- send_unknown counts as settled: it needs a person, not the worker.
CREATE OR REPLACE FUNCTION public.dispatcher_maybe_complete_campaign()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_campaign_id uuid := CASE WHEN tg_op = 'DELETE' THEN old.campaign_id ELSE new.campaign_id END;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.campaign_contacts cc
    WHERE cc.campaign_id = v_campaign_id
      AND cc.status IN ('pending', 'retry_scheduled', 'leased')
  ) THEN
    UPDATE public.campaigns c
    SET status = 'completed', finished_at = now()
    WHERE c.id = v_campaign_id
      AND c.status = 'live';
  END IF;

  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_campaign_contacts_maybe_complete
  AFTER UPDATE OF status ON public.campaign_contacts
  FOR EACH ROW
  WHEN (
    new.status IS DISTINCT FROM old.status
    AND new.status IN ('sent', 'failed', 'canceled', 'send_unknown')
  )
  EXECUTE FUNCTION public.dispatcher_maybe_complete_campaign();

CREATE TRIGGER trg_campaign_contacts_maybe_complete_after_delete
  AFTER DELETE ON public.campaign_contacts
  FOR EACH ROW
  EXECUTE FUNCTION public.dispatcher_maybe_complete_campaign();

-- ── Reporting views ────────────────────────────────────────────────────────

CREATE VIEW public.campaign_send_state
WITH (security_invoker = true)
AS
SELECT
  c.id AS campaign_id,
  c.status AS campaign_status,
  count(cc.id) FILTER (WHERE cc.status = 'pending')::integer AS pending_count,
  count(cc.id) FILTER (WHERE cc.status = 'leased')::integer AS leased_count,
  count(cc.id) FILTER (WHERE cc.status = 'retry_scheduled')::integer AS retry_scheduled_count,
  count(cc.id) FILTER (WHERE cc.status = 'sent')::integer AS sent_count,
  count(cc.id) FILTER (WHERE cc.status = 'failed')::integer AS failed_count,
  count(cc.id) FILTER (WHERE cc.status = 'send_unknown')::integer AS send_unknown_count,
  count(cc.id) FILTER (WHERE cc.status = 'canceled')::integer AS canceled_count
FROM public.campaigns c
LEFT JOIN public.campaign_contacts cc ON cc.campaign_id = c.id
GROUP BY c.id, c.status;

-- The queue a person works through: sends whose outcome only the provider
-- (or the recipient's inbox) can confirm.
CREATE VIEW public.unknown_sends
WITH (security_invoker = true)
AS
SELECT
  cc.id AS campaign_contact_id,
  cc.campaign_id,
  ct.email AS to_email,
  c.sender_id,
  t.provider_email AS sender_email,
  cc.lease_token,
  coalesce(t.issued_at, a.requested_at, cc.leased_at) AS token_issued_at,
  cc.lease_expires_at,
  a.id AS attempt_id,
  a.error_message AS attempt_error_message
FROM public.campaign_contacts cc
JOIN public.campaigns c ON c.id = cc.campaign_id
JOIN public.contacts ct ON ct.id = cc.contact_id
LEFT JOIN public.send_attempts a ON a.lease_token = cc.lease_token
LEFT JOIN public.send_tokens t ON t.id = a.send_token_id
WHERE cc.status = 'send_unknown';

REVOKE ALL ON TABLE public.campaign_send_state FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.unknown_sends FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.campaign_send_state TO service_role;
GRANT SELECT ON TABLE public.unknown_sends TO service_role;

REVOKE ALL ON FUNCTION public.dispatcher_lock_receipt_recipient(uuid, uuid, text[]) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.dispatcher_receipt_sent(uuid, uuid, text, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_receipt_unknown(uuid, uuid, text, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_receipt_failed(uuid, uuid, text, timestamptz, timestamptz, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_mark_expired_sends_unknown(timestamptz) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.dispatcher_receipt_sent(uuid, uuid, text, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_receipt_unknown(uuid, uuid, text, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_receipt_failed(uuid, uuid, text, timestamptz, timestamptz, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_mark_expired_sends_unknown(timestamptz) TO service_role;

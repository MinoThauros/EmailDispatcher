-- pg-email-dispatcher: campaign lifecycle and unsubscribe.
--
-- draft -> live -> completed, with paused and canceled on the side. A
-- campaign is claimable only while live, so pausing or canceling closes the
-- admission doorway immediately; a recipient already holding a lease still
-- finishes through its receipt.

CREATE OR REPLACE FUNCTION public.dispatcher_sender_has_active_credentials(p_sender_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.sender_credentials sc
    JOIN public.senders s ON s.id = sc.sender_id
    WHERE sc.sender_id = p_sender_id
      AND sc.status = 'active'
      AND s.disabled_at IS NULL
  );
$$;

-- Members are added to campaign_contacts while the campaign is a draft.
-- Going live drops suppressed addresses (the one suppression check before
-- sending starts; unsubscribes during a send are handled by
-- dispatcher_record_unsubscribe) and schedules the rest for p_send_at.
-- Returns the number of recipients that will be sent to.
CREATE OR REPLACE FUNCTION public.dispatcher_campaign_go_live(
  p_campaign_id uuid,
  p_send_at timestamptz DEFAULT now()
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_campaign public.campaigns;
  v_send_at timestamptz := coalesce(p_send_at, now());
  v_count integer;
BEGIN
  PERFORM public.dispatcher_require_service_role();

  SELECT * INTO v_campaign
  FROM public.campaigns
  WHERE id = p_campaign_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign not found' USING errcode = 'P0001';
  END IF;

  IF v_campaign.status <> 'draft' THEN
    RAISE EXCEPTION 'only draft campaigns can go live (status=%)', v_campaign.status
      USING errcode = 'P0001';
  END IF;

  IF NOT public.dispatcher_sender_has_active_credentials(v_campaign.sender_id) THEN
    RAISE EXCEPTION 'sender has no active mailbox credentials' USING errcode = 'P0001';
  END IF;

  UPDATE public.campaign_contacts cc
  SET status = 'canceled', last_error = 'suppressed'
  FROM public.contacts ct
  WHERE cc.campaign_id = p_campaign_id
    AND cc.status = 'pending'
    AND ct.id = cc.contact_id
    AND EXISTS (
      SELECT 1 FROM public.suppressions s
      WHERE s.normalized_email = ct.normalized_email
    );

  UPDATE public.campaign_contacts cc
  SET send_after = v_send_at
  WHERE cc.campaign_id = p_campaign_id
    AND cc.status = 'pending';

  -- The BEFORE trigger rejects this when no sendable recipient is left.
  UPDATE public.campaigns
  SET status = 'live', send_at = v_send_at
  WHERE id = p_campaign_id;

  SELECT count(*)::integer INTO v_count
  FROM public.campaign_contacts cc
  WHERE cc.campaign_id = p_campaign_id
    AND cc.status = 'pending';

  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.dispatcher_pause_campaign(p_campaign_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status text;
BEGIN
  PERFORM public.dispatcher_require_service_role();

  SELECT status INTO v_status
  FROM public.campaigns
  WHERE id = p_campaign_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign not found';
  END IF;

  IF v_status <> 'live' THEN
    RAISE EXCEPTION 'only live campaigns can be paused (status=%)', v_status;
  END IF;

  UPDATE public.campaigns
  SET status = 'paused', pause_reason = 'user_paused', paused_at = now()
  WHERE id = p_campaign_id;
END;
$$;

-- Resume is manual only, and only once the sender can send again.
CREATE OR REPLACE FUNCTION public.dispatcher_resume_campaign(p_campaign_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_campaign public.campaigns;
BEGIN
  PERFORM public.dispatcher_require_service_role();

  SELECT * INTO v_campaign
  FROM public.campaigns
  WHERE id = p_campaign_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign not found';
  END IF;

  IF v_campaign.status <> 'paused' THEN
    RAISE EXCEPTION 'only paused campaigns can be resumed (status=%)', v_campaign.status;
  END IF;

  IF NOT public.dispatcher_sender_has_active_credentials(v_campaign.sender_id) THEN
    RAISE EXCEPTION 'cannot resume: the sender must reconnect their mailbox first';
  END IF;

  UPDATE public.campaigns
  SET status = 'live', pause_reason = NULL, paused_at = NULL
  WHERE id = p_campaign_id;

  -- Everything may have settled while paused; completion only runs on live.
  IF NOT EXISTS (
    SELECT 1 FROM public.campaign_contacts cc
    WHERE cc.campaign_id = p_campaign_id
      AND cc.status IN ('pending', 'retry_scheduled', 'leased')
  ) THEN
    UPDATE public.campaigns
    SET status = 'completed', finished_at = now()
    WHERE id = p_campaign_id;
  END IF;
END;
$$;

-- Status flips first so the completion trigger (which only completes live
-- campaigns) cannot revive it. Leased rows are left to finish via receipts.
CREATE OR REPLACE FUNCTION public.dispatcher_cancel_campaign(p_campaign_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status text;
BEGIN
  PERFORM public.dispatcher_require_service_role();

  SELECT status INTO v_status
  FROM public.campaigns
  WHERE id = p_campaign_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign not found';
  END IF;

  IF v_status = 'canceled' THEN
    RETURN;
  END IF;

  IF v_status NOT IN ('draft', 'live', 'paused') THEN
    RAISE EXCEPTION 'only draft, live or paused campaigns can be canceled (status=%)', v_status;
  END IF;

  UPDATE public.campaigns
  SET status = 'canceled', canceled_at = now()
  WHERE id = p_campaign_id;

  UPDATE public.campaign_contacts
  SET status = 'canceled'
  WHERE campaign_id = p_campaign_id
    AND status IN ('pending', 'retry_scheduled');
END;
$$;

-- Called by your public unsubscribe endpoint (link click or RFC 8058
-- one-click POST). Idempotent. Also stops any not-yet-sent email to that
-- address in campaigns that are already running. Returns false for an
-- unknown token so the endpoint can show a generic page without writing.
CREATE OR REPLACE FUNCTION public.dispatcher_record_unsubscribe(
  p_token uuid,
  p_via text DEFAULT 'unsubscribe_link'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_token public.unsubscribe_tokens;
BEGIN
  PERFORM public.dispatcher_require_service_role();

  IF p_via NOT IN ('unsubscribe_link', 'one_click_header', 'admin_action') THEN
    RAISE EXCEPTION 'invalid suppression source: %', p_via;
  END IF;

  SELECT * INTO v_token
  FROM public.unsubscribe_tokens t
  WHERE t.token = p_token;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  INSERT INTO public.suppressions (normalized_email, contact_id, suppressed_via)
  VALUES (v_token.normalized_email, v_token.contact_id, p_via)
  ON CONFLICT (normalized_email) DO NOTHING;

  UPDATE public.campaign_contacts cc
  SET status = 'canceled', last_error = 'unsubscribed'
  FROM public.contacts ct
  WHERE ct.id = cc.contact_id
    AND ct.normalized_email = v_token.normalized_email
    AND cc.status IN ('pending', 'retry_scheduled');

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.dispatcher_sender_has_active_credentials(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_campaign_go_live(uuid, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_pause_campaign(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_resume_campaign(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_cancel_campaign(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_record_unsubscribe(uuid, text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.dispatcher_sender_has_active_credentials(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_campaign_go_live(uuid, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_pause_campaign(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_resume_campaign(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_cancel_campaign(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_record_unsubscribe(uuid, text) TO service_role;

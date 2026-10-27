-- pg-email-dispatcher: token admission.
--
-- dispatcher_claim_next_send_token is the only doorway to the provider. In one
-- transaction it picks a due recipient, derives the sender's reputation scope,
-- takes advisory locks on that scope and sender, applies warmup, cooldown,
-- 24h cap and sender-interval rules, row-locks the recipient with
-- FOR UPDATE SKIP LOCKED, and writes the token log and attempt ledger. It
-- returns either one issued token or no_work with the next known unblock time.

CREATE OR REPLACE FUNCTION public.dispatcher_is_public_mailbox_domain(p_domain text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path = public
AS $$
  SELECT lower(btrim(p_domain)) = ANY (ARRAY[
    'gmail.com', 'googlemail.com',
    'outlook.com', 'hotmail.com', 'live.com', 'msn.com',
    'yahoo.com', 'ymail.com', 'rocketmail.com', 'yahoo.ca', 'yahoo.co.uk',
    'yahoo.com.au', 'yahoo.co.jp', 'yahoo.fr',
    'icloud.com', 'me.com', 'mac.com',
    'aol.com',
    'proton.me', 'protonmail.com',
    'gmx.com', 'gmx.net', 'gmx.de', 'gmx.us', 'gmx.co.uk',
    'mail.ru', 'bk.ru', 'inbox.ru', 'list.ru',
    'yandex.com', 'yandex.ru', 'ya.ru',
    'fastmail.com', 'fastmail.fm'
  ]);
$$;

-- Consumer mailboxes are judged per mailbox (with Gmail dot and +tag
-- aliases folded together); custom domains are judged per domain.
CREATE OR REPLACE FUNCTION public.dispatcher_resolve_scope_key(p_sender_email text)
RETURNS TABLE (
  normalized_sender_email text,
  normalized_domain text,
  scope_key text,
  scope_key_type text
)
LANGUAGE plpgsql
IMMUTABLE
STRICT
SET search_path = public
AS $$
DECLARE
  v_email text := lower(btrim(p_sender_email));
  v_at integer := strpos(v_email, '@');
  v_local text;
  v_domain text;
BEGIN
  IF v_at <= 1 OR v_at >= char_length(v_email) THEN
    RETURN;
  END IF;

  v_local := left(v_email, v_at - 1);
  v_domain := substring(v_email FROM v_at + 1);

  IF public.dispatcher_is_public_mailbox_domain(v_domain) THEN
    v_local := split_part(v_local, '+', 1);

    IF v_domain IN ('gmail.com', 'googlemail.com') THEN
      v_local := replace(v_local, '.', '');
    END IF;

    IF v_local = '' THEN
      RETURN;
    END IF;

    RETURN QUERY SELECT v_local || '@' || v_domain, v_domain, v_local || '@' || v_domain, 'public_mailbox'::text;
  ELSE
    RETURN QUERY SELECT v_local || '@' || v_domain, v_domain, v_domain, 'custom_domain'::text;
  END IF;
END;
$$;

-- Progressive warmup. Age is measured from the scope's first issued token.
-- Edit this function to change the ramp; the claim reads it on every call.
CREATE OR REPLACE FUNCTION public.dispatcher_warmup_policy(
  p_warmup_started_at timestamptz,
  p_now timestamptz DEFAULT now()
)
RETURNS TABLE (
  tier text,
  rolling_24h_cap integer,
  min_interval_seconds integer
)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  WITH age AS (
    SELECT CASE
      WHEN p_warmup_started_at IS NULL THEN interval '0 seconds'
      ELSE greatest(coalesce(p_now, now()) - p_warmup_started_at, interval '0 seconds')
    END AS value
  )
  SELECT
    CASE
      WHEN age.value < interval '24 hours' THEN '0-24h'
      WHEN age.value < interval '72 hours' THEN '24-72h'
      WHEN age.value < interval '168 hours' THEN '72-168h'
      WHEN age.value < interval '336 hours' THEN '168-336h'
      ELSE '336h+'
    END,
    CASE
      WHEN age.value < interval '24 hours' THEN 30
      WHEN age.value < interval '72 hours' THEN 60
      WHEN age.value < interval '168 hours' THEN 150
      WHEN age.value < interval '336 hours' THEN 300
      ELSE 480
    END,
    CASE
      WHEN age.value < interval '24 hours' THEN 600
      WHEN age.value < interval '72 hours' THEN 300
      WHEN age.value < interval '168 hours' THEN 240
      ELSE 180
    END
  FROM age;
$$;

CREATE OR REPLACE FUNCTION public.dispatcher_scope_lifecycle(
  p_scope public.sender_reputation_scopes,
  p_now timestamptz DEFAULT now()
)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_scope.state = 'safety_paused' THEN 'safety_paused'
    WHEN p_scope.state = 'cooling_down'
      AND (p_scope.cooldown_until IS NULL OR p_scope.cooldown_until > coalesce(p_now, now()))
      THEN 'cooling_down'
    WHEN p_scope.warmup_started_at IS NOT NULL
      AND p_scope.warmup_started_at <= coalesce(p_now, now()) - interval '336 hours'
      THEN 'warmed'
    ELSE 'warming'
  END;
$$;

CREATE OR REPLACE FUNCTION public.dispatcher_record_scope_deferral(
  p_worker_id uuid,
  p_scope_id uuid,
  p_scope_key_type text,
  p_deferral_reason text,
  p_tier text,
  p_now timestamptz DEFAULT now()
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.scope_deferral_rollups (
    worker_id, scope_id, scope_key_type, deferral_reason, tier,
    deferred_count, first_deferred_at, last_deferred_at
  )
  VALUES (
    p_worker_id, p_scope_id, p_scope_key_type, p_deferral_reason, p_tier,
    1, coalesce(p_now, now()), coalesce(p_now, now())
  )
  ON CONFLICT (worker_id, scope_id, deferral_reason, tier)
  DO UPDATE SET
    deferred_count = public.scope_deferral_rollups.deferred_count + 1,
    last_deferred_at = excluded.last_deferred_at;
END;
$$;

-- Deletes and returns one worker's rollups so each group is reported once.
CREATE OR REPLACE FUNCTION public.dispatcher_collect_scope_deferrals(p_worker_id uuid)
RETURNS TABLE (
  worker_id uuid,
  scope_id uuid,
  scope_key_type text,
  deferral_reason text,
  tier text,
  deferred_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.dispatcher_require_service_role();

  RETURN QUERY
  WITH deleted AS (
    DELETE FROM public.scope_deferral_rollups r
    WHERE r.worker_id = p_worker_id
    RETURNING r.worker_id, r.scope_id, r.scope_key_type, r.deferral_reason, r.tier, r.deferred_count
  )
  SELECT d.worker_id, d.scope_id, d.scope_key_type, d.deferral_reason, d.tier, d.deferred_count
  FROM deleted d
  ORDER BY d.deferred_count DESC, d.deferral_reason;
END;
$$;

-- Operator escape hatches. Both write an audit row.
CREATE OR REPLACE FUNCTION public.dispatcher_admin_clear_safety_pause(
  p_scope_id uuid,
  p_actor_email text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_before public.sender_reputation_scopes;
  v_after public.sender_reputation_scopes;
BEGIN
  PERFORM public.dispatcher_require_service_role();

  IF nullif(btrim(p_actor_email), '') IS NULL THEN
    RAISE EXCEPTION 'actor email is required';
  END IF;

  SELECT * INTO v_before
  FROM public.sender_reputation_scopes s
  WHERE s.id = p_scope_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sender reputation scope not found';
  END IF;

  UPDATE public.sender_reputation_scopes s
  SET
    state = 'warming',
    cooldown_until = NULL,
    cooldown_reason = NULL,
    safety_paused_at = NULL,
    safety_pause_reason = NULL
  WHERE s.id = p_scope_id
  RETURNING * INTO v_after;

  INSERT INTO public.sender_reputation_scope_audit (scope_id, action, actor_email, payload)
  VALUES (
    p_scope_id,
    'clear_safety_pause',
    public.normalize_email(p_actor_email),
    jsonb_build_object(
      'previous_state', v_before.state,
      'new_state', v_after.state,
      'previous_safety_pause_reason', v_before.safety_pause_reason
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.dispatcher_admin_fast_forward_warmup(
  p_scope_id uuid,
  p_warmup_started_at timestamptz,
  p_actor_email text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_before public.sender_reputation_scopes;
BEGIN
  PERFORM public.dispatcher_require_service_role();

  IF nullif(btrim(p_actor_email), '') IS NULL THEN
    RAISE EXCEPTION 'actor email is required';
  END IF;

  IF p_warmup_started_at IS NULL THEN
    RAISE EXCEPTION 'warmup_started_at is required';
  END IF;

  SELECT * INTO v_before
  FROM public.sender_reputation_scopes s
  WHERE s.id = p_scope_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sender reputation scope not found';
  END IF;

  UPDATE public.sender_reputation_scopes s
  SET warmup_started_at = p_warmup_started_at
  WHERE s.id = p_scope_id;

  INSERT INTO public.sender_reputation_scope_audit (scope_id, action, actor_email, payload)
  VALUES (
    p_scope_id,
    'fast_forward_warmup',
    public.normalize_email(p_actor_email),
    jsonb_build_object(
      'previous_warmup_started_at', v_before.warmup_started_at,
      'new_warmup_started_at', p_warmup_started_at
    )
  );
END;
$$;

-- Returns the existing stable unsubscribe token for an address, or mints one.
CREATE OR REPLACE FUNCTION public.dispatcher_unsubscribe_token_for(
  p_normalized_email text,
  p_contact_id uuid
)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  INSERT INTO public.unsubscribe_tokens (normalized_email, contact_id)
  VALUES (p_normalized_email, p_contact_id)
  ON CONFLICT (normalized_email) DO UPDATE
    SET contact_id = coalesce(public.unsubscribe_tokens.contact_id, excluded.contact_id)
  RETURNING token;
$$;

CREATE OR REPLACE FUNCTION public.dispatcher_claim_next_send_token(
  p_worker_id uuid,
  p_recipient_lease_seconds integer,
  p_sender_min_interval_seconds integer,
  p_now timestamptz DEFAULT now(),
  p_candidate_limit integer DEFAULT 50
)
RETURNS TABLE (
  state text,
  next_eligible_at timestamptz,
  worker_id uuid,
  sender_id uuid,
  sender_min_interval_seconds integer,
  campaign_contact_id uuid,
  campaign_id uuid,
  contact_id uuid,
  to_email text,
  recipient_first_name text,
  lease_token uuid,
  send_token_id uuid,
  attempt_id uuid,
  attempt_no integer,
  subject text,
  preview_text text,
  body_html text,
  body_text text,
  from_name text,
  from_email text,
  reply_to_email text,
  unsubscribe_token uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_now timestamptz := coalesce(p_now, now());
  v_lease_seconds integer := greatest(coalesce(p_recipient_lease_seconds, 300), 1);
  v_sender_min_interval integer := greatest(coalesce(p_sender_min_interval_seconds, 1), 1);
  v_candidate_limit integer := greatest(coalesce(p_candidate_limit, 1), 1);
  v_effective_interval integer;
  v_candidate record;
  v_scope public.sender_reputation_scopes;
  v_policy record;
  v_locked record;
  v_skipped_scopes text[] := ARRAY[]::text[];
  v_skipped_senders uuid[] := ARRAY[]::uuid[];
  v_latest_issued_at timestamptz;
  v_sender_next_at timestamptz;
  v_scope_usage integer;
  v_scope_next_at timestamptz;
  v_next_eligible_at timestamptz;
  v_lease_token uuid;
  v_attempt_no integer;
  v_send_token_id uuid;
  v_attempt_id uuid;
BEGIN
  PERFORM public.dispatcher_require_service_role();

  -- Candidates are interleaved across scopes and recruiters (rank 1 of every
  -- scope first, then rank 2, ...) so one busy recruiter cannot starve
  -- their teammates.
  FOR v_candidate IN
    WITH due AS (
      SELECT
        cc.id AS campaign_contact_id,
        cc.campaign_id,
        cc.contact_id,
        cc.created_at AS cc_created_at,
        coalesce(cc.next_retry_at, cc.send_after) AS due_time,
        c.sender_id,
        c.subject,
        c.preview_text,
        c.body_html,
        c.body_text,
        c.reply_to_email,
        ct.email AS to_email,
        ct.normalized_email AS to_normalized_email,
        ct.first_name AS recipient_first_name,
        sc.provider_email AS sender_email,
        s.display_name AS sender_display_name,
        identity.normalized_sender_email,
        identity.normalized_domain,
        identity.scope_key,
        identity.scope_key_type
      FROM public.campaign_contacts cc
      JOIN public.campaigns c ON c.id = cc.campaign_id
      JOIN public.contacts ct ON ct.id = cc.contact_id
      JOIN public.senders s ON s.id = c.sender_id AND s.disabled_at IS NULL
      JOIN public.sender_credentials sc
        ON sc.sender_id = c.sender_id
       AND sc.provider = 'google'
       AND sc.status = 'active'
      CROSS JOIN LATERAL public.dispatcher_resolve_scope_key(sc.provider_email) identity
      WHERE c.status = 'live'
        AND c.send_at <= v_now
        AND cc.status IN ('pending', 'retry_scheduled')
        AND coalesce(cc.next_retry_at, cc.send_after) <= v_now
    ),
    ranked AS (
      SELECT
        due.*,
        row_number() OVER (PARTITION BY due.scope_key ORDER BY due.due_time, due.cc_created_at) AS scope_rank,
        row_number() OVER (PARTITION BY due.sender_id ORDER BY due.due_time, due.cc_created_at) AS sender_rank
      FROM due
    )
    SELECT *
    FROM ranked
    ORDER BY scope_rank, sender_rank, due_time, cc_created_at
    LIMIT v_candidate_limit
  LOOP
    IF v_candidate.scope_key = ANY (v_skipped_scopes)
      OR v_candidate.sender_id = ANY (v_skipped_senders) THEN
      CONTINUE;
    END IF;

    INSERT INTO public.sender_reputation_scopes (
      scope_key, scope_key_type, normalized_sender_email, normalized_domain
    )
    VALUES (
      v_candidate.scope_key,
      v_candidate.scope_key_type,
      v_candidate.normalized_sender_email,
      v_candidate.normalized_domain
    )
    ON CONFLICT (scope_key) DO UPDATE SET
      scope_key_type = excluded.scope_key_type,
      normalized_sender_email = excluded.normalized_sender_email,
      normalized_domain = excluded.normalized_domain
    RETURNING * INTO v_scope;

    -- Another worker is admitting for this scope or sender right now: skip
    -- rather than wait, and let that worker's pacing decision stand.
    IF NOT pg_try_advisory_xact_lock(hashtext('dispatcher:scope:' || v_scope.id::text)) THEN
      v_skipped_scopes := array_append(v_skipped_scopes, v_candidate.scope_key);
      CONTINUE;
    END IF;

    IF NOT pg_try_advisory_xact_lock(hashtext('dispatcher:sender:' || v_candidate.sender_id::text)) THEN
      v_skipped_senders := array_append(v_skipped_senders, v_candidate.sender_id);
      CONTINUE;
    END IF;

    SELECT * INTO v_policy
    FROM public.dispatcher_warmup_policy(v_scope.warmup_started_at, v_now);

    v_effective_interval := greatest(v_sender_min_interval, v_policy.min_interval_seconds);

    IF v_scope.state = 'safety_paused' THEN
      PERFORM public.dispatcher_record_scope_deferral(
        p_worker_id, v_scope.id, v_scope.scope_key_type, 'scope_safety_paused', v_policy.tier, v_now
      );
      v_skipped_scopes := array_append(v_skipped_scopes, v_candidate.scope_key);
      CONTINUE;
    END IF;

    IF v_scope.state = 'cooling_down'
      AND v_scope.cooldown_until IS NOT NULL
      AND v_scope.cooldown_until > v_now THEN
      v_next_eligible_at := least(coalesce(v_next_eligible_at, v_scope.cooldown_until), v_scope.cooldown_until);
      PERFORM public.dispatcher_record_scope_deferral(
        p_worker_id, v_scope.id, v_scope.scope_key_type, 'scope_cooling_down', v_policy.tier, v_now
      );
      v_skipped_scopes := array_append(v_skipped_scopes, v_candidate.scope_key);
      CONTINUE;
    END IF;

    SELECT max(t.issued_at) INTO v_latest_issued_at
    FROM public.send_tokens t
    WHERE t.sender_id = v_candidate.sender_id;

    v_sender_next_at := v_latest_issued_at + make_interval(secs => v_effective_interval);

    IF v_sender_next_at IS NOT NULL AND v_sender_next_at > v_now THEN
      v_next_eligible_at := least(coalesce(v_next_eligible_at, v_sender_next_at), v_sender_next_at);
      PERFORM public.dispatcher_record_scope_deferral(
        p_worker_id, v_scope.id, v_scope.scope_key_type, 'sender_interval', v_policy.tier, v_now
      );
      v_skipped_senders := array_append(v_skipped_senders, v_candidate.sender_id);
      CONTINUE;
    END IF;

    SELECT count(*)::integer INTO v_scope_usage
    FROM public.send_tokens t
    WHERE t.reputation_scope_id = v_scope.id
      AND t.issued_at > v_now - interval '24 hours';

    IF v_scope_usage >= v_policy.rolling_24h_cap THEN
      SELECT min(t.issued_at) + interval '24 hours' INTO v_scope_next_at
      FROM public.send_tokens t
      WHERE t.reputation_scope_id = v_scope.id
        AND t.issued_at > v_now - interval '24 hours';

      IF v_scope_next_at IS NOT NULL THEN
        v_next_eligible_at := least(coalesce(v_next_eligible_at, v_scope_next_at), v_scope_next_at);
      END IF;

      PERFORM public.dispatcher_record_scope_deferral(
        p_worker_id, v_scope.id, v_scope.scope_key_type, 'scope_cap_hit', v_policy.tier, v_now
      );
      v_skipped_scopes := array_append(v_skipped_scopes, v_candidate.scope_key);
      CONTINUE;
    END IF;

    -- Re-check eligibility under the row lock: the candidate scan above is not
    -- locked, so the campaign may have been paused or the credential rotated.
    SELECT cc.id, cc.attempt_count
      INTO v_locked
    FROM public.campaign_contacts cc
    WHERE cc.id = v_candidate.campaign_contact_id
      AND cc.status IN ('pending', 'retry_scheduled')
      AND coalesce(cc.next_retry_at, cc.send_after) <= v_now
      AND EXISTS (
        SELECT 1
        FROM public.campaigns c
        JOIN public.sender_credentials sc
          ON sc.sender_id = c.sender_id
         AND sc.provider = 'google'
         AND sc.status = 'active'
        WHERE c.id = cc.campaign_id
          AND c.status = 'live'
          AND c.send_at <= v_now
          AND c.sender_id = v_candidate.sender_id
          AND sc.provider_email = v_candidate.sender_email
      )
    FOR UPDATE OF cc SKIP LOCKED;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    v_lease_token := gen_random_uuid();
    v_attempt_no := v_locked.attempt_count + 1;

    UPDATE public.campaigns c
    SET started_at = coalesce(c.started_at, v_now)
    WHERE c.id = v_candidate.campaign_id;

    UPDATE public.campaign_contacts cc
    SET
      status = 'leased',
      lease_token = v_lease_token,
      leased_at = v_now,
      lease_expires_at = v_now + make_interval(secs => v_lease_seconds),
      attempt_count = v_attempt_no
    WHERE cc.id = v_locked.id;

    UPDATE public.sender_reputation_scopes s
    SET
      warmup_started_at = coalesce(s.warmup_started_at, v_now),
      last_token_issued_at = v_now
    WHERE s.id = v_scope.id;

    INSERT INTO public.send_tokens (
      sender_id, campaign_contact_id, lease_token, issued_at,
      reputation_scope_id, reputation_scope_key, provider_email
    )
    VALUES (
      v_candidate.sender_id, v_locked.id, v_lease_token, v_now,
      v_scope.id, v_scope.scope_key, v_candidate.sender_email
    )
    RETURNING id INTO v_send_token_id;

    INSERT INTO public.send_attempts (
      campaign_id, campaign_contact_id, sender_id, send_token_id,
      attempt_no, status, lease_token, requested_at
    )
    VALUES (
      v_candidate.campaign_id, v_locked.id, v_candidate.sender_id, v_send_token_id,
      v_attempt_no, 'started', v_lease_token, v_now
    )
    RETURNING id INTO v_attempt_id;

    RETURN QUERY
    SELECT
      'token_issued'::text,
      NULL::timestamptz,
      p_worker_id,
      v_candidate.sender_id,
      v_effective_interval,
      v_locked.id,
      v_candidate.campaign_id,
      v_candidate.contact_id,
      v_candidate.to_email,
      v_candidate.recipient_first_name,
      v_lease_token,
      v_send_token_id,
      v_attempt_id,
      v_attempt_no,
      v_candidate.subject,
      v_candidate.preview_text,
      v_candidate.body_html,
      v_candidate.body_text,
      v_candidate.sender_display_name,
      v_candidate.sender_email,
      v_candidate.reply_to_email,
      public.dispatcher_unsubscribe_token_for(v_candidate.to_normalized_email, v_candidate.contact_id);

    RETURN;
  END LOOP;

  RETURN QUERY
  SELECT
    'no_work'::text,
    v_next_eligible_at,
    p_worker_id,
    NULL::uuid,
    v_sender_min_interval,
    NULL::uuid, NULL::uuid, NULL::uuid,
    NULL::text, NULL::text,
    NULL::uuid, NULL::uuid, NULL::uuid,
    NULL::integer,
    NULL::text, NULL::text, NULL::text, NULL::text,
    NULL::text, NULL::text, NULL::text,
    NULL::uuid;
END;
$$;

REVOKE ALL ON FUNCTION public.dispatcher_is_public_mailbox_domain(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_resolve_scope_key(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_warmup_policy(timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_scope_lifecycle(public.sender_reputation_scopes, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_record_scope_deferral(uuid, uuid, text, text, text, timestamptz) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.dispatcher_collect_scope_deferrals(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_admin_clear_safety_pause(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_admin_fast_forward_warmup(uuid, timestamptz, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_unsubscribe_token_for(text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatcher_claim_next_send_token(uuid, integer, integer, timestamptz, integer) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.dispatcher_is_public_mailbox_domain(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_resolve_scope_key(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_warmup_policy(timestamptz, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_scope_lifecycle(public.sender_reputation_scopes, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_collect_scope_deferrals(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_admin_clear_safety_pause(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_admin_fast_forward_warmup(uuid, timestamptz, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_unsubscribe_token_for(text, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispatcher_claim_next_send_token(uuid, integer, integer, timestamptz, integer) TO service_role;

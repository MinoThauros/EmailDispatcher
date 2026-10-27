-- Campaign lifecycle: pause/resume, credential loss, cancel, unsubscribe,
-- go-live guards, and who may call the RPCs.
BEGIN;
\ir _helpers.psql
SELECT plan(17);

SELECT pg_temp.new_sender('jordan@acme.test') AS sender \gset
SELECT pg_temp.new_campaign(:'sender', 4) AS campaign \gset
SELECT public.dispatcher_campaign_go_live(:'campaign', now());

-- ── Pause closes the doorway; resume reopens it ──
SELECT public.dispatcher_pause_campaign(:'campaign');
SELECT is((SELECT state FROM pg_temp.claim(now())), 'no_work', 'a paused campaign issues no tokens');

SELECT public.dispatcher_resume_campaign(:'campaign');
SELECT * FROM pg_temp.claim(now()) \gset a_
SELECT is(:'a_state'::text, 'token_issued', 'a resumed campaign sends again');

-- ── Losing the mailbox pauses live campaigns, and resume refuses ──
SELECT public.dispatcher_mark_sender_reauth_required(:'sender', 'google', 'invalid_grant: Bearer ya29.secret-token');

SELECT results_eq(
  format('SELECT status, pause_reason::text FROM public.campaigns WHERE id = %L', :'campaign'),
  $$ VALUES ('paused'::text, 'sender_oauth_revoked'::text) $$,
  'credential loss auto-pauses the sender''s live campaigns'
);
SELECT unalike(
  (SELECT last_error FROM public.sender_credentials WHERE sender_id = :'sender'),
  '%ya29.secret-token%',
  'token-looking values are redacted from the stored error'
);
SELECT throws_like(
  format('SELECT public.dispatcher_resume_campaign(%L)', :'campaign'),
  '%reconnect%',
  'resume is refused until the sender reconnects'
);
SELECT is(
  (SELECT count(*)::integer FROM public.dispatcher_resolve_sender_credentials(:'sender') WHERE access_token IS NOT NULL),
  0,
  'tokens are not handed out while reauth is required'
);

-- The lease taken before the pause still completes through its receipt.
SELECT lives_ok(
  format('SELECT public.dispatcher_receipt_sent(%L, %L, %L)', :'a_campaign_contact_id', :'a_lease_token', 'msg-a'),
  'an in-flight lease finishes after the pause'
);

SELECT public.dispatcher_upsert_sender_credentials(:'sender', 'google', 'jordan@acme.test', 'new-access-token', NULL);
SELECT lives_ok(
  format('SELECT public.dispatcher_resume_campaign(%L)', :'campaign'),
  'resume works once the mailbox is reconnected'
);
SELECT is(
  (SELECT refresh_token FROM public.dispatcher_resolve_sender_credentials(:'sender')),
  'test-refresh-token',
  'reconnecting without a new refresh token keeps the stored one'
);

-- ── Cancel stops unsent recipients but leaves an in-flight lease alone ──
SELECT * FROM pg_temp.claim(now() + interval '600 seconds') \gset b_
SELECT public.dispatcher_cancel_campaign(:'campaign');

SELECT results_eq(
  format(
    'SELECT status, count(*)::integer FROM public.campaign_contacts WHERE campaign_id = %L GROUP BY status ORDER BY status',
    :'campaign'
  ),
  $$ VALUES ('canceled'::text, 2), ('leased', 1), ('sent', 1) $$,
  'cancel cancels pending recipients and keeps the leased one'
);
SELECT is(
  (SELECT status FROM public.campaigns WHERE id = :'campaign'),
  'canceled',
  'the campaign is canceled'
);

-- ── Unsubscribe ──
SELECT pg_temp.new_campaign(:'sender', 3, 'u') AS campaign2 \gset
SELECT public.dispatcher_campaign_go_live(:'campaign2', now());
SELECT * FROM pg_temp.claim(now() + interval '1200 seconds') \gset u_

-- u_ was leased; unsubscribe a different, still-pending member.
SELECT public.dispatcher_unsubscribe_token_for('u3@example.com', NULL) AS u3_token \gset

SELECT ok(public.dispatcher_record_unsubscribe(:'u3_token', 'one_click_header'), 'a known token unsubscribes');
SELECT ok(NOT public.dispatcher_record_unsubscribe(gen_random_uuid()), 'an unknown token is a no-op');
SELECT is(
  (
    SELECT cc.status
    FROM public.campaign_contacts cc
    JOIN public.contacts ct ON ct.id = cc.contact_id
    WHERE cc.campaign_id = :'campaign2' AND ct.normalized_email = 'u3@example.com'
  ),
  'canceled',
  'unsubscribing stops pending email to that address in running campaigns'
);

SELECT pg_temp.new_campaign(:'sender', 3, 'u') AS campaign3 \gset
SELECT is(
  public.dispatcher_campaign_go_live(:'campaign3', now()),
  2,
  'go-live leaves out suppressed addresses'
);

-- ── Guards ──
INSERT INTO public.campaigns (sender_id, name, subject) VALUES (:'sender', 'Empty', 'Nothing') RETURNING id AS empty_campaign \gset
SELECT throws_like(
  format('SELECT public.dispatcher_campaign_go_live(%L)', :'empty_campaign'),
  '%at least one sendable contact%',
  'a campaign with no sendable members cannot go live'
);

SET LOCAL ROLE anon;
SELECT throws_ok(
  $$ SELECT * FROM public.dispatcher_claim_next_send_token(gen_random_uuid(), 300, 180) $$,
  '42501',
  NULL,
  'anon cannot call the dispatcher'
);
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;

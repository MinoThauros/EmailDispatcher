-- Receipts: lease-token checks, retries and their limit, unknown-beats-
-- duplicate, late receipts, expired leases, and campaign completion.
BEGIN;
\ir _helpers.psql
SELECT plan(23);

SELECT pg_temp.new_sender('maya@acme.test') AS sender \gset
SELECT pg_temp.new_campaign(:'sender', 5) AS campaign \gset
SELECT public.dispatcher_campaign_go_live(:'campaign', now());

-- ── Sent ──
SELECT * FROM pg_temp.claim(now()) \gset a_

SELECT throws_ok(
  format(
    'SELECT public.dispatcher_receipt_sent(%L, gen_random_uuid(), %L)',
    :'a_campaign_contact_id', 'msg-1'
  ),
  'stale or invalid send lease token',
  'a receipt with the wrong lease token is rejected'
);

SELECT lives_ok(
  format(
    'SELECT public.dispatcher_receipt_sent(%L, %L, %L)',
    :'a_campaign_contact_id', :'a_lease_token', 'msg-1'
  ),
  'a receipt with the issued lease token is accepted'
);
SELECT results_eq(
  format(
    'SELECT status, provider_message_id, lease_token FROM public.campaign_contacts WHERE id = %L',
    :'a_campaign_contact_id'
  ),
  $$ VALUES ('sent'::text, 'msg-1'::text, NULL::uuid) $$,
  'sent clears the lease and stores the provider message id'
);
SELECT is(
  (SELECT status FROM public.send_attempts WHERE lease_token = :'a_lease_token'),
  'sent',
  'the attempt ledger matches'
);
SELECT throws_like(
  format(
    'SELECT public.dispatcher_receipt_sent(%L, %L, %L)',
    :'a_campaign_contact_id', :'a_lease_token', 'msg-1'
  ),
  '%lease token%',
  'replaying the same receipt is rejected'
);

-- ── Retryable failure ──
SELECT * FROM pg_temp.claim(now() + interval '600 seconds') \gset b_

SELECT lives_ok(
  format(
    'SELECT public.dispatcher_receipt_failed(%L, %L, %L, %L::timestamptz, now(), %L)',
    :'b_campaign_contact_id', :'b_lease_token', 'rate limited',
    now() + interval '2 hours', 'rate_limited'
  ),
  'a retryable failure is accepted'
);
SELECT results_eq(
  format(
    'SELECT status, next_retry_at, lease_token FROM public.campaign_contacts WHERE id = %L',
    :'b_campaign_contact_id'
  ),
  format(
    'VALUES (%L::text, %L::timestamptz, NULL::uuid)',
    'retry_scheduled', now() + interval '2 hours'
  ),
  'a retryable failure schedules the retry and releases the lease'
);

-- ── The fifth attempt is the last ──
UPDATE public.campaign_contacts
SET attempt_count = 4, next_retry_at = now() - interval '1 minute'
WHERE id = :'b_campaign_contact_id';

SELECT * FROM pg_temp.claim(now() + interval '1200 seconds') \gset b5_

SELECT is(:'b5_campaign_contact_id'::uuid, :'b_campaign_contact_id'::uuid, 'the due retry is claimed first');
SELECT is(:'b5_attempt_no'::integer, 5, 'it is the fifth attempt');

SELECT public.dispatcher_receipt_failed(
  :'b_campaign_contact_id', :'b5_lease_token', 'rate limited again',
  now() + interval '3 hours', now(), 'rate_limited'
);
SELECT is(
  (SELECT status FROM public.campaign_contacts WHERE id = :'b_campaign_contact_id'),
  'failed',
  'a retryable failure on the last attempt is terminal'
);

-- ── Unknown beats duplicate ──
SELECT * FROM pg_temp.claim(now() + interval '1800 seconds') \gset c_

SELECT public.dispatcher_receipt_unknown(:'c_campaign_contact_id', :'c_lease_token', 'gmail send timed out');
SELECT results_eq(
  format(
    'SELECT status, lease_token FROM public.campaign_contacts WHERE id = %L',
    :'c_campaign_contact_id'
  ),
  format('VALUES (%L::text, %L::uuid)', 'send_unknown', :'c_lease_token'),
  'an ambiguous outcome becomes send_unknown and keeps its lease token'
);
SELECT isnt(
  (SELECT campaign_contact_id FROM pg_temp.claim(now() + interval '2400 seconds')),
  :'c_campaign_contact_id'::uuid,
  'a send_unknown recipient is never claimed again automatically'
);
SELECT lives_ok(
  format(
    'SELECT public.dispatcher_receipt_sent(%L, %L, %L)',
    :'c_campaign_contact_id', :'c_lease_token', 'msg-late'
  ),
  'a late receipt with the original token resolves the unknown'
);
SELECT is(
  (SELECT status FROM public.campaign_contacts WHERE id = :'c_campaign_contact_id'),
  'sent',
  'the late receipt marks it sent'
);

-- ── Expired lease (worker crashed after taking the token) ──
-- The claim at +2400s above leased a fourth recipient that never gets a receipt.
SELECT is(
  public.dispatcher_mark_expired_sends_unknown(now() + interval '2400 seconds' + interval '301 seconds'),
  1,
  'an expired lease is swept'
);
SELECT is(
  (SELECT count(*)::integer FROM public.unknown_sends),
  1,
  'it appears in the unknown_sends queue'
);
SELECT is(
  (SELECT status FROM public.send_attempts WHERE status = 'send_unknown' LIMIT 1),
  'send_unknown',
  'the attempt ledger records the unknown'
);

-- ── Operator-action failure safety-pauses the reputation scope ──
SELECT * FROM pg_temp.claim(now() + interval '3600 seconds') \gset d_

-- One more member so the campaign still has work once this send fails.
INSERT INTO public.contacts (email) VALUES ('late-joiner@example.com');
INSERT INTO public.campaign_contacts (campaign_id, contact_id, send_after)
SELECT :'campaign', id, now() FROM public.contacts WHERE email = 'late-joiner@example.com';


SELECT public.dispatcher_receipt_failed(
  :'d_campaign_contact_id', :'d_lease_token', 'Gmail API disabled for this project',
  NULL, now(), 'operator_action'
);
SELECT is(
  (SELECT state FROM public.sender_reputation_scopes WHERE scope_key = 'acme.test'),
  'safety_paused',
  'an operator-action failure safety-pauses the scope'
);

SELECT is(
  (SELECT status FROM public.campaigns WHERE id = :'campaign'),
  'live',
  'the campaign is still live with one recipient left'
);
SELECT is(
  (SELECT state FROM pg_temp.claim(now() + interval '7200 seconds')),
  'no_work',
  'a safety-paused scope issues no tokens'
);

SELECT public.dispatcher_admin_clear_safety_pause(
  (SELECT id FROM public.sender_reputation_scopes WHERE scope_key = 'acme.test'),
  'oncall@acme.test'
);
SELECT is(
  (SELECT count(*)::integer FROM public.sender_reputation_scope_audit WHERE action = 'clear_safety_pause'),
  1,
  'clearing a safety pause is audited'
);

-- ── Completion ──
SELECT * FROM pg_temp.claim(now() + interval '7200 seconds') \gset e_
SELECT public.dispatcher_receipt_sent(:'e_campaign_contact_id', :'e_lease_token', 'msg-e');

SELECT is(
  (SELECT status FROM public.campaigns WHERE id = :'campaign'),
  'completed',
  'the campaign completes when nothing is left to send'
);
SELECT results_eq(
  format(
    'SELECT sent_count, failed_count, send_unknown_count FROM public.campaign_send_state WHERE campaign_id = %L',
    :'campaign'
  ),
  $$ VALUES (3, 2, 1) $$,
  'campaign_send_state rolls up the outcomes'
);

SELECT * FROM finish();
ROLLBACK;

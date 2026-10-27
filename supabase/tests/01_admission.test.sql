-- Token admission: one token per claim, sender pacing, warmup caps, and
-- shared reputation scopes.
BEGIN;
\ir _helpers.psql
SELECT plan(19);

SELECT pg_temp.new_sender('alice@acme.test') AS alice \gset
SELECT pg_temp.new_campaign(:'alice', 32, 'alice-r') AS alice_campaign \gset

SELECT is(
  public.dispatcher_campaign_go_live(:'alice_campaign', now()),
  32,
  'go-live schedules every member'
);

-- ── First claim issues exactly one token ──
SELECT * FROM pg_temp.claim(now()) \gset c1_

SELECT is(:'c1_state'::text, 'token_issued', 'first claim issues a token');
SELECT is(
  (SELECT status FROM public.campaign_contacts WHERE id = :'c1_campaign_contact_id'),
  'leased',
  'the claimed recipient is leased'
);
SELECT is(
  (SELECT count(*)::integer FROM public.campaign_contacts WHERE status = 'leased'),
  1,
  'only one recipient is leased per claim'
);
SELECT is(
  (SELECT status FROM public.send_attempts WHERE lease_token = :'c1_lease_token'),
  'started',
  'the attempt ledger records a started attempt for the token'
);
SELECT is(
  (SELECT count(*)::integer FROM public.send_tokens WHERE lease_token = :'c1_lease_token'),
  1,
  'the token log records the issued token'
);
SELECT isnt(:'c1_unsubscribe_token'::uuid, NULL, 'the claim returns an unsubscribe token');

-- ── Sender pacing: the 0-24h warmup tier spaces sends 600s apart ──
SELECT * FROM pg_temp.claim(now() + interval '1 second') \gset c2_

SELECT is(:'c2_state'::text, 'no_work', 'a second claim inside the sender interval gets no work');
SELECT is(
  :'c2_next_eligible_at'::timestamptz,
  now() + interval '600 seconds',
  'no_work reports when the sender is next eligible'
);
SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.dispatcher_collect_scope_deferrals('00000000-0000-0000-0000-00000000000a')
    WHERE deferral_reason = 'sender_interval'
  ),
  'the deferral is recorded with its reason'
);

SELECT * FROM pg_temp.claim(now() + interval '600 seconds') \gset c3_

SELECT is(:'c3_state'::text, 'token_issued', 'the sender can send again once the interval has passed');
SELECT isnt(:'c3_campaign_contact_id'::uuid, :'c1_campaign_contact_id'::uuid, 'the next token goes to a different recipient');

-- ── Rolling 24h cap: 30 tokens per scope in the first warmup tier ──
SELECT is(
  (
    SELECT count(*)::integer
    FROM generate_series(2, 29) AS k
    CROSS JOIN LATERAL pg_temp.claim(now() + k * interval '600 seconds') c
    WHERE c.state = 'token_issued'
  ),
  28,
  'paced claims keep issuing until the cap'
);

SELECT * FROM pg_temp.claim(now() + 30 * interval '600 seconds') \gset c31_

SELECT is(:'c31_state'::text, 'no_work', 'the 31st token in 24h is refused');
SELECT is(
  :'c31_next_eligible_at'::timestamptz,
  now() + interval '24 hours',
  'the cap reopens 24h after the oldest token in the window'
);

-- A second sender on the same custom domain shares the scope, so the cap
-- applies to it too. A Gmail sender is its own scope and is unaffected.
SELECT pg_temp.new_sender('bob@acme.test') AS bob \gset
SELECT pg_temp.new_campaign(:'bob', 2, 'bob-r') AS bob_campaign \gset
SELECT public.dispatcher_campaign_go_live(:'bob_campaign', now());

SELECT is(
  (SELECT state FROM pg_temp.claim(now() + 30 * interval '600 seconds')),
  'no_work',
  'senders on one custom domain share its reputation cap'
);

SELECT pg_temp.new_sender('carol@gmail.com') AS carol \gset
SELECT pg_temp.new_campaign(:'carol', 2, 'carol-r') AS carol_campaign \gset
SELECT public.dispatcher_campaign_go_live(:'carol_campaign', now());

SELECT is(
  (SELECT state FROM pg_temp.claim(now() + 30 * interval '600 seconds')),
  'token_issued',
  'a public-mailbox sender has its own scope'
);

-- ── Scope keys ──
SELECT results_eq(
  $$ SELECT scope_key, scope_key_type FROM public.dispatcher_resolve_scope_key('First.Last+promo@GMail.com') $$,
  $$ VALUES ('firstlast@gmail.com', 'public_mailbox') $$,
  'Gmail dots and +tags fold into one mailbox scope'
);
SELECT results_eq(
  $$ SELECT scope_key, scope_key_type FROM public.dispatcher_resolve_scope_key('Ops@Acme.test') $$,
  $$ VALUES ('acme.test', 'custom_domain') $$,
  'a custom domain is one scope'
);

SELECT * FROM finish();
ROLLBACK;

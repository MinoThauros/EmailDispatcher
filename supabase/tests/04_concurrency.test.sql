-- Concurrency: a second real session (via dblink) holds locks while this one
-- claims. Fixtures must be committed so the other session can see them, so
-- this suite creates and removes its own rows instead of rolling back.
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS dblink WITH SCHEMA extensions;

-- ── Committed fixtures ──
DELETE FROM public.campaign_contacts WHERE contact_id IN (SELECT id FROM public.contacts WHERE email LIKE 'race-%');
DELETE FROM public.campaigns WHERE name = 'race campaign';
SELECT public.dispatcher_disconnect_sender(id) FROM public.senders WHERE email = 'race@race.test';
DELETE FROM public.sender_credentials WHERE provider_email = 'race@race.test';
DELETE FROM public.senders WHERE email = 'race@race.test';
DELETE FROM public.contacts WHERE email LIKE 'race-%';

INSERT INTO public.senders (email) VALUES ('race@race.test') RETURNING id AS sender \gset
SELECT public.dispatcher_upsert_sender_credentials(:'sender', 'google', 'race@race.test', 'race-token', NULL);
INSERT INTO public.campaigns (sender_id, name, subject, body_html)
VALUES (:'sender', 'race campaign', 'Race', '<p>Race</p>')
RETURNING id AS campaign \gset
INSERT INTO public.contacts (email) VALUES ('race-1@example.com') RETURNING id AS contact1 \gset
INSERT INTO public.contacts (email) VALUES ('race-2@example.com') RETURNING id AS contact2 \gset
INSERT INTO public.campaign_contacts (campaign_id, contact_id, send_after)
VALUES (:'campaign', :'contact1', now() - interval '2 minutes')
RETURNING id AS recipient1 \gset
INSERT INTO public.campaign_contacts (campaign_id, contact_id, send_after)
VALUES (:'campaign', :'contact2', now() - interval '1 minute')
RETURNING id AS recipient2 \gset
UPDATE public.campaigns SET status = 'live', send_at = now() - interval '2 minutes' WHERE id = :'campaign';

-- Connect back over the network address this session came in on: loopback is
-- trust-authenticated, and dblink requires a password-authenticated connection.
SELECT dblink_connect(
  'race',
  format(
    'host=%s port=%s dbname=postgres user=postgres password=postgres',
    host(inet_server_addr()),
    inet_server_port()
  )
);

BEGIN;
SELECT plan(4);

-- Only the race campaign is claimable inside this transaction.
UPDATE public.campaigns SET status = 'paused' WHERE status = 'live' AND id <> :'campaign';

-- ── Another worker is admitting for this sender ──
SELECT * FROM dblink('race', format('SELECT pg_advisory_lock(hashtext(%L))::text', 'dispatcher:sender:' || :'sender')) AS t(locked text);

SELECT is(
  (
    SELECT state
    FROM public.dispatcher_claim_next_send_token('00000000-0000-0000-0000-0000000000b1', 300, 180)
  ),
  'no_work',
  'a sender locked by another worker is skipped, not waited on'
);
SELECT is(
  (SELECT count(*)::integer FROM public.send_tokens WHERE sender_id = :'sender'),
  0,
  'no token is issued for the locked sender'
);

SELECT * FROM dblink('race', format('SELECT pg_advisory_unlock(hashtext(%L))::text', 'dispatcher:sender:' || :'sender')) AS t(unlocked text);

-- ── Another worker holds the oldest recipient's row ──
SELECT dblink_exec('race', 'BEGIN');
SELECT * FROM dblink('race', format('SELECT 1 FROM public.campaign_contacts WHERE id = %L FOR UPDATE', :'recipient1')) AS t(locked integer);

SELECT is(
  (
    SELECT campaign_contact_id
    FROM public.dispatcher_claim_next_send_token('00000000-0000-0000-0000-0000000000b2', 300, 180)
  ),
  :'recipient2'::uuid,
  'a row-locked recipient is skipped and the next one is claimed'
);
SELECT is(
  (SELECT status FROM public.campaign_contacts WHERE id = :'recipient1'),
  'pending',
  'the locked recipient is untouched'
);

SELECT dblink_exec('race', 'ROLLBACK');

SELECT * FROM finish();
ROLLBACK;

-- ── Cleanup ──
SELECT dblink_disconnect('race');
DELETE FROM public.campaign_contacts WHERE campaign_id = :'campaign';
DELETE FROM public.campaigns WHERE id = :'campaign';
SELECT public.dispatcher_disconnect_sender(:'sender');
DELETE FROM public.sender_credentials WHERE sender_id = :'sender';
DELETE FROM public.senders WHERE id = :'sender';
DELETE FROM public.contacts WHERE email LIKE 'race-%';

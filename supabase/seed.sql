-- Demo data for `supabase db reset`. Every address uses the reserved
-- example.* domains, and the access tokens are placeholders: run the worker
-- with SIMULATE_SENDS=true (the default).
--
-- Four senders across three reputation scopes:
--   alice@example.com and bob@example.com share the example.com scope
--   carol@example.org and dave@example.net each have their own

DO $$
DECLARE
  v_sender record;
  v_campaign_id uuid;
BEGIN
  INSERT INTO public.contacts (email, first_name)
  SELECT 'reader' || n || '@example.net', (ARRAY['Ada', 'Grace', 'Linus', 'Barbara', 'Ken'])[1 + n % 5]
  FROM generate_series(1, 40) AS n;

  FOR v_sender IN
    SELECT *
    FROM (VALUES
      ('alice@example.com', 'Alice at Example', 0),
      ('bob@example.com', 'Bob at Example', 10),
      ('carol@example.org', 'Carol at Example Org', 20),
      ('dave@example.net', 'Dave at Example Net', 30)
    ) AS s(email, display_name, contact_offset)
  LOOP
    INSERT INTO public.senders (email, display_name)
    VALUES (v_sender.email, v_sender.display_name)
    RETURNING id INTO v_campaign_id;

    PERFORM public.dispatcher_upsert_sender_credentials(
      v_campaign_id, 'google', v_sender.email, 'simulated-access-token', 'simulated-refresh-token',
      now() + interval '1 hour'
    );

    INSERT INTO public.campaigns (sender_id, name, subject, body_html)
    VALUES (
      v_campaign_id,
      'October update from ' || v_sender.display_name,
      'Hi {{first_name}}, here is what changed this month',
      '<p>Hi {{first_name}},</p><p>Here is what changed this month.</p>'
        || '<p style="font-size:12px"><a href="{{unsubscribe_url}}">Unsubscribe</a></p>'
    )
    RETURNING id INTO v_campaign_id;

    INSERT INTO public.campaign_contacts (campaign_id, contact_id)
    SELECT v_campaign_id, ct.id
    FROM public.contacts ct
    WHERE ct.email IN (
      SELECT 'reader' || n || '@example.net'
      FROM generate_series(v_sender.contact_offset + 1, v_sender.contact_offset + 10) AS n
    );

    PERFORM public.dispatcher_campaign_go_live(v_campaign_id, now());
  END LOOP;
END;
$$;

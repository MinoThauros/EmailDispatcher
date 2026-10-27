# Architecture

The dispatcher is a Postgres-owned send pipeline for recruiter outreach: recruiters email candidates from their own mailboxes, and recruiting teams share their company domain's reputation. The worker is deliberately thin: it wakes up, asks the database for one admitted send, calls the email provider only after the database has issued a token, writes the provider's answer back through a receipt RPC, and repeats until there is no admissible work or its time budget runs out.

Everything that has to be true across crashes and concurrent workers lives in SQL. Everything that talks to the outside world lives in TypeScript and never decides which candidate gets an email.

## Design principles

1. **Database first.** The worker keeps no state Postgres cannot reconstruct. Killing it mid-send at any line leaves the database consistent.
2. **Provider calls happen outside transactions.** Admission commits, then the worker calls Gmail. No database lock is held across a network call.
3. **One token, one recipient attempt.** There is no batch leasing in the send path. A worker holds at most one token at a time.
4. **Token issuance is the dangerous boundary.** Once a token exists, the system assumes an external send may happen or may already have happened.
5. **Unknown beats duplicate.** An ambiguous or interrupted send becomes `send_unknown`, never an automatic retry.
6. **No long-lived ownership.** No worker owns a campaign or a recruiter beyond the single admission transaction. Correctness comes from that transaction's locks.
7. **Reporting is derived.** Campaign completion and rollups come from recipient rows and the attempt ledger, not from worker memory.

## Data model

| Table | Role |
|---|---|
| `senders` | One per recruiter: the identity a campaign is sent as |
| `sender_credentials` | The recruiter's connected mailbox plus Vault secret ids for its OAuth tokens |
| `contacts` | Candidates, unique by normalized email |
| `campaigns` | The outreach run: content, recruiter, `draft → live → completed` |
| `campaign_contacts` | Campaign membership **and** the queue item; one row is one email to one candidate |
| `sender_reputation_scopes` | Warmup and safety state per personal mailbox or company domain |
| `send_tokens` | Every issued token; drives pacing and the rolling 24h cap |
| `send_attempts` | The attempt ledger: one row per token, with its outcome |
| `suppressions`, `unsubscribe_tokens` | Candidate opt-outs and stable unsubscribe links |
| `scope_deferral_rollups` | Why candidates were deferred, drained once per worker cycle |

`campaign_contacts` doubling as the queue is intentional. There is no separate job table to fall out of sync with membership, and "what happened to this candidate in this campaign" is one row.

## Admission: `dispatcher_claim_next_send_token`

This function is the only doorway to the provider. In one transaction it:

1. **Scans due candidates.** Live campaigns past `send_at`, candidates `pending` or `retry_scheduled` and due, recruiters not disabled, with an active credential. The scope key comes from the credential's `provider_email`, the mailbox that will actually appear in `From:`.
2. **Interleaves them.** Candidates are ranked within their scope and within their sender, then ordered by those ranks. The first candidate of every scope comes before the second of any, so one recruiter's large campaign can't starve their teammates'.
3. **Upserts the reputation scope** for the candidate.
4. **Tries the scope lock, then the sender lock** with `pg_try_advisory_xact_lock`. If another worker holds either, that scope or sender is skipped for the rest of this call. Skip, never wait: waiting would serialize workers behind each other's network calls, and the other worker's pacing decision is the correct one anyway.
5. **Applies the policy.** Safety pause, then cooldown, then the sender interval (the stricter of the worker floor and the warmup tier), then the scope's rolling 24h cap. Each deferral is recorded with its reason, and the earliest unblock time is tracked for `no_work`.
6. **Locks the recipient** with `FOR UPDATE SKIP LOCKED` and re-checks eligibility under the lock. The scan in step 1 is unlocked, so the campaign may have been paused or the mailbox rotated since.
7. **Issues the token.** It sets `leased` with a random `lease_token` and an expiry, increments `attempt_count`, starts the scope's warmup clock if this is its first token, and writes the `send_tokens` and `send_attempts` rows. It returns the rendered send context plus a stable unsubscribe token.

If no candidate survives, it returns `no_work` with `next_eligible_at`.

### Why scopes, not senders, carry the cap

Mailbox providers judge reputation per domain for company domains and per mailbox for consumer addresses. Two recruiters on the same team sending from `acme.com` affect the same reputation, so they share one warmup clock and one 24h cap. Gmail aliases (`first.last+promo@gmail.com`) fold into one mailbox scope. The per-recruiter interval still applies to each person, so a shared scope doesn't let one recruiter burst.

## Provider execution

`executeGmailSend` spends one token:

- It resolves credentials from Vault (`dispatcher_resolve_sender_credentials` returns tokens only while the credential is `active`) and refuses to send if the mailbox changed since admission.
- It fills `{{first_name}}` and `{{unsubscribe_url}}`, builds a single-line-header MIME message with `List-Unsubscribe` and one-click headers, and posts it to Gmail.
- On a **401** it re-reads credentials first, because another worker may already have refreshed them. Otherwise it refreshes once, stores the new token, and resends once. A second 401 parks the credential as `reauth_required`. An `invalid_grant` is checked against the latest stored refresh token, in case a concurrent refresh rotated it.

Outcomes map to receipts:

| Provider result | Category | Receipt |
|---|---|---|
| 2xx | — | `sent` |
| 429, quota reasons | `rate_limited` | `failed` with `retry_after` (from `Retry-After`) |
| 5xx, 408, timeout, network error | `provider_ambiguous` | `unknown` |
| 401 after refresh, `invalid_grant` | `reauth_required` | `failed`, credential parked, campaigns auto-pause |
| API disabled, domain policy, OAuth client errors | `operator_action` | `failed`, scope safety-paused |
| anything else (bad recipient, malformed) | `provider_rejected` | `failed` |

A refresh that is rate-limited or ambiguous becomes a retry, not an unknown: nothing was sent yet.

## Receipts

`dispatcher_receipt_sent`, `_failed` and `_unknown` each lock the recipient, require the presented `lease_token` to match the one on the row, and require a state that is awaiting that receipt. That rejects:

- a receipt from a worker whose lease already expired and was swept,
- a duplicate delivery of the same receipt,
- a receipt for the wrong recipient.

`receipt_unknown` keeps the lease token on the row, so a late `receipt_sent` or `receipt_failed` from the original worker can still resolve it. `receipt_failed` turns a retryable failure on the fifth attempt into `failed`, and an `operator_action` failure into a scope safety pause.

## Recovery

At the start of every cycle `dispatcher_mark_expired_sends_unknown` sweeps `leased` rows past their expiry (`FOR UPDATE SKIP LOCKED`, so it never blocks a live receipt) and marks them and their attempts `send_unknown`. A worker that died after Gmail accepted the message but before the receipt therefore produces an unknown, not a second email.

`unknown_sends` is the queue a person reconciles, typically by checking the recruiter's Sent folder and calling the matching receipt.

## Lifecycle

- **Go live** cancels suppressed members, schedules the rest for `send_at`, and refuses if no sendable member remains or the sender has no active mailbox.
- **Pause** and **cancel** flip the campaign status first. Admission keys on `status = 'live'`, so the doorway closes immediately. Cancel also cancels `pending` and `retry_scheduled` rows. A row that is already `leased` finishes through its receipt.
- **Credential loss** (`active` → anything else) pauses the recruiter's live campaigns through a trigger. Resume is manual and requires a connected mailbox.
- **Completion** is a trigger on recipient status: when nothing is `pending`, `retry_scheduled` or `leased`, a live campaign becomes `completed`. `send_unknown` counts as settled, because it needs a person, not the worker.
- **Unsubscribe** writes a suppression and cancels unsent email to that candidate in running campaigns.

## Security

- Every table has RLS enabled with no policies, and `anon` and `authenticated` grants are revoked. Every RPC is executable only by `service_role` (EXECUTE is revoked from `PUBLIC`, `anon` and `authenticated`), and the entry points also check the caller's role inside the function.
- OAuth tokens live only in Supabase Vault. Credential rows store Vault secret ids.
- Provider errors are redacted before they are stored or logged (bearer tokens, `*_token=` pairs, token-shaped JSON fields); credential errors are redacted again in SQL, including JWT-shaped and long opaque strings.
- MIME headers are forced to a single line, and every address is validated as exactly one plain address, so content can't inject headers or extra recipients.
- The cron route fails closed without `CRON_SECRET` and compares it in constant time.

## How the guarantees are tested

| Guarantee | Where |
|---|---|
| One lease per claim, token log and ledger written together | `supabase/tests/01_admission.test.sql` |
| Sender interval, rolling cap, shared domain scope, Gmail alias folding | `supabase/tests/01_admission.test.sql` |
| Lease-token checks, replay rejection, retry limit, unknown and late receipt, expiry sweep, safety pause, completion | `supabase/tests/02_receipts.test.sql` |
| Pause/resume, credential loss, cancel, unsubscribe, go-live guards, `anon` denied | `supabase/tests/03_lifecycle.test.sql` |
| A second real session holding the sender lock or the recipient row is skipped, not waited on | `supabase/tests/04_concurrency.test.sql` |
| Sequential spending, shutdown deadline, malformed claims refused | `test/worker.test.ts` |
| Failure classification, refresh-once, concurrent-refresh reuse, mailbox mismatch | `test/gmail-failures.test.ts`, `test/gmail-send.test.ts` |
| Header injection, address validation, merge-field escaping, token redaction | `test/mime.test.ts` |

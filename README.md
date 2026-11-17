# Couple Life

Mobile-first relationship and life-simulation prototype built with React, TypeScript, Vite, Phaser, Supabase Auth/PostgreSQL/Realtime, and a PWA shell.

## Run locally

Use Node.js 20 or later:

```sh
npm install
npm run dev
npm run build
```

Without Supabase client configuration the app offers a local demo stored in browser storage.

## Implemented client and backend workflows

- Registration, login, password recovery, persistent sessions, partner invitations and relationship setup.
- Couple-bound shared world state, revision checking, private movement broadcasts and presence.
- Shared coin wallet, individual diamond wallets, server-validated shop transactions, business purchases/upgrades/income, pet adoption/care, pet accessories, and home-room expansion.
- Six server-authoritative online arcade room types with single-use partner invites, couple membership checks, revision-checked moves, and no game currency rewards.
- Relationship timeline with text/photo/video memories, comments, reactions, and private media.
- Ten retained billboard placements, advertiser inquiries, admin-reviewed campaign scheduling, creative storage, click/impression reporting, and one server-validated daily diamond reward per player and campaign after an eligible completed view.
- PWA manifest, icons, service worker, standalone install mode and touch controls.

Presence and online play are implemented in code but require authenticated two-account verification. A read-only live schema probe found migration 006 media columns, migration 007/008 columns absent, migration 009 tables absent, and ten active billboards. The public API cannot confirm the migration ledger or whether every statement from migration 006 is installed.

## Supabase setup

The root `.env.local` uses these public client variables:

```env
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_PUBLIC_ANON_KEY
VITE_PUBLIC_APP_URL=https://your-deployed-domain.example
```

Never put a service-role key in a `VITE_` variable. The owner confirmed through the linked migration list that 001-006 are applied remotely and 007-010 are pending. Read-only REST probes found 006 media columns; did not find 007 room columns, 008 campaign/inquiry columns or click table, or 009 room tables. Public REST cannot inspect policies, constraints, or the migration ledger.

- 006 adds private relationship media/comments/reactions, corrects post ownership, and limits ad-view sessions.
- 007 adds private server-authoritative online game rooms.
- 008 adds advertiser inquiry, campaign approval, storage, and click/impression reporting. Its original click-reward behavior is superseded by migration 011.
- 009 adds pet accessories and server-authoritative home expansion.
- 010 tightens the media path/type constraint for existing installations without deleting or rewriting old rows.
- 011 awards diamonds for eligible completed ad views, with no mandatory external click and one claim per player/campaign/UTC day.

Migrations 001-010 were previously applied in order to an isolated PostgreSQL-compatible PGlite runtime with Supabase objects stubbed; this is not a production rehearsal. Migration 011 passed focused PGlite checks for completion rewards, same-day deduplication, idempotent replay, and click-without-reward behavior.

## Advertising and payments

The ten Phaser signs remain placeholders. Campaign timestamps gate display and view eligibility; no scheduled job rewrites expired campaign status. Campaign quotes are not payments. In migration 011, outbound clicks are optional and do not grant currency.

Real-money payments are not implemented. No provider sandbox, webhook signing secret, product mapping, or payment event is configured. Payment fulfillment must use verified server-side webhooks, not a browser success page. Review storefront billing rules before distributing digital purchases through iOS or Android stores.

## Remaining product work and launch blockers

- Apply migrations 007-010 in order, followed by local migration 011. The owner-confirmed ledger and public REST object probes are separate evidence; public REST cannot inspect RLS, storage policies, or constraints.
- Run authenticated account registration, invitation/acceptance, setup, shared state, RLS, wallet, business, pet, ad and game-room checks with dedicated test accounts.
- Test movement, presence, and games using two separate accounts/devices. These have not been tested here.
- Connected neighborhood discovery, privacy settings and visits remain unavailable until a server-backed visitation model is implemented; the connected UI does not invent neighbors.
- Select a payment provider, configure sandbox products and webhook secrets, and verify signed events before any real-money purchase flow.
- Configure an authorized platform administrator and test campaign approval/reporting after migration 008.
- Verify iPhone, Android, tablet and desktop installation/touch behavior on real devices.
- Phaser's lazy-loaded chunk is approximately 1.49 MB before gzip; optimize and measure on target phones.
- Date/time display follows browser locale and numeric balances use locale formatting; full translation, saved time-zone preferences, and multi-currency pricing are not implemented.

## Verification

- `npm run build`: passed TypeScript checks and production Vite build.
- Service worker and smoke-script JavaScript syntax checks: passed.
- PWA manifest JSON parse and production manifest link: passed. Service worker source syntax passes; actual install/offline behavior still needs a supported browser/device check.
- Production bundle warning: lazy-loaded Phaser chunk is about 1.49 MB before gzip.
- `npm audit --omit=dev --audit-level=moderate`: passed with 0 known vulnerabilities.
- Two-account live smoke check: blocked because test-account credentials are unavailable.
- Supabase CLI/database admin access was unavailable in this shell; no migrations were applied or marked. Owner-confirmed remote ledger: 001-006 applied; 007-010 pending. Migration 011 is local only. The focused isolated reward-path checks passed.
- Live read-only API checks: posts media columns returned HTTP 200; game-room and campaign columns returned HTTP 400; home-room tables returned HTTP 404; active billboard count was 10. These checks do not prove migration history or authenticated behavior.
- Browser viewport check: 390 px mobile, 768 px tablet, and 1366 px desktop all loaded the production sign-up screen with no horizontal overflow and no console errors. The authenticated game/world screens were not accessible without test accounts.
- Vercel SPA rewrite and no-cache headers are prepared in `vercel.json`; deployment itself was not performed.
- No production data was changed during this run.

The two-account smoke check is `node scripts/live-couple-smoke.mjs`; it reads public app configuration without printing it and requires two existing test accounts in local process variables. It does not mutate data unless `COUPLE_TEST_ALLOW_WRITES=true`, which must only be used with a dedicated test couple.
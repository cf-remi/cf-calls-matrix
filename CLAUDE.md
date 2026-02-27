# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

**cf-calls-matrix** is a self-hostable Matrix homeserver (spec v1.17) + Element Web client,
running entirely on Cloudflare Workers edge infrastructure.

- **Server** (`src/`) — Matrix homeserver using Hono, D1, KV, R2, Durable Objects, Workflows
- **Client** (`client/`) — Patched Element Web v1.12.11, deployed as a Worker with Static Assets

A live instance runs at `matrix.goodshab.com` (server) and `goodshab.com` (client).

## Repository Layout

```
cf-calls-matrix/
├── src/                        Matrix server source (Hono/TypeScript)
├── migrations/                 D1 SQL migration files (16 total)
├── client/
│   ├── patches/                Git patches applied on top of element-web v1.12.11
│   ├── config.json.template    Element config template ({{SERVER_NAME}}, {{BRAND}})
│   ├── wrangler.toml.template  Client wrangler config template
│   ├── worker.js               Minimal Cloudflare Worker entrypoint
│   ├── .assetsignore           Files excluded from static asset upload
│   ├── .well-known/            Android app association file
│   └── build.sh                Clone element-web, apply patches, build
├── wrangler.jsonc.template     Server wrangler config template
├── setup.sh                    Interactive setup: create resources, generate configs, deploy
└── .github/workflows/
    ├── deploy-server.yml       CI: deploy server on push to src/
    ├── deploy-client.yml       CI: build + deploy client on push to client/
    └── release-client.yml      CI: build client, attach to GitHub Release on tag push
```

**Generated files (gitignored — created by setup.sh or CI):**
- `wrangler.jsonc` — server config with real resource IDs
- `client/config.json` — Element config with real server URL and brand
- `client/wrangler.toml` — client deployment config with real account ID and domain
- `client/dist/` — built Element Web output

## Development Commands

```bash
npm run dev              # Local dev server (wrangler dev)
npm run deploy           # Deploy server to Cloudflare
npm run typecheck        # TypeScript type checking (tsc --noEmit)
npm run lint             # ESLint on src/
npm run test             # Vitest
npm run db:migrate       # Run schema.sql on remote D1
npm run db:migrate:local # Run schema.sql on local D1
```

## Architecture

**Framework:** Hono web framework with typed `AppEnv` bindings for Cloudflare resources.

**Entry point:** `src/index.ts` — creates the Hono app, applies global middleware (CORS → Logger → Rate Limit), mounts all route modules, and exports Durable Objects + Workflows.

**Layered structure:**
- `src/api/` — Route handlers (30+ modules). Each exports a Hono instance mounted in the main app. Largest: `federation.ts` (103KB), `sliding-sync.ts` (81KB), `admin.ts` (80KB), `rooms.ts` (73KB).
- `src/middleware/` — Auth (`requireAuth()`), rate limiting (DO-based sliding window), federation auth (Ed25519 X-Matrix), idempotency.
- `src/services/` — Business logic: `database.ts` (D1 queries, no ORM), `federation-keys.ts`, `server-discovery.ts`, `email.ts` (Cloudflare Email Service), `oidc.ts`, `turn.ts`, `livekit.ts`, `cloudflare-calls.ts`, `rtk.ts`.
- `src/durable-objects/` — 8 DOs: Room (WebSocket coordination), Sync, Federation (queue), CallRoom (video), Admin, UserKeys (E2EE), Push, RateLimit.
- `src/workflows/` — `RoomJoinWorkflow` (federation handshake with retry), `PushNotificationWorkflow`.
- `src/types/` — `env.ts` (Cloudflare bindings), `matrix.ts` (PDU/event types).
- `src/utils/` — `crypto.ts` (hashing/signing), `ids.ts` (Matrix ID generation), `errors.ts` (MatrixApiError + Errors factory).
- `src/admin/dashboard.ts` — Embedded admin web UI at `/admin`.
- `migrations/` — D1 schema files (schema.sql + numbered migrations 002–015).

**Storage bindings (defined in `wrangler.jsonc`):**
- D1 — Relational data (users, rooms, events, memberships, etc.)
- KV namespaces: `SESSIONS`, `DEVICE_KEYS`, `ONE_TIME_KEYS`, `CROSS_SIGNING_KEYS`, `CACHE`, `ACCOUNT_DATA`
- R2 `MEDIA` — Media file storage

**Key patterns:**
- Auth: token from `Authorization: Bearer` or `?access_token=`, SHA-256 hashed, looked up in D1 `access_tokens`. Middleware sets `userId`/`deviceId` on context.
- Errors: Use `MatrixApiError` class and `Errors` factory for standardized Matrix JSON responses (`errcode`, `error`).
- Database: Direct D1 prepared statements — no ORM. All queries in `src/services/database.ts` or inline in route handlers.
- IDs follow Matrix format: `@user:domain`, `!room_id:domain`, `$event_id:domain`, `#alias:domain`.
- Federation: Ed25519 signing, X-Matrix header validation, server key caching in KV.
- Real-time: Hibernatable WebSockets via RoomDurableObject, long-polling `/sync`, Sliding Sync (MSC3575/MSC4186) for Element X.
- Passwords hashed with PBKDF2-SHA256 (100,000 iterations).

**TypeScript config:** Strict mode, ES2022 target, `@/*` path alias maps to `src/*`, `@cloudflare/workers-types`.

## Client Patches

The `client/patches/` directory contains git patches applied on top of element-web v1.12.11:

- **`call-toggle-and-hangup.patch`** — Two fixes to call behavior:
  1. Video button toggles the call view (show/hide) instead of opening a new call if one already exists
  2. Hanging up closes the call view entirely rather than showing the post-hangup lobby screen

To regenerate after modifying element-web source:
```bash
cd /path/to/element-web-v1.12.11
git diff HEAD > /path/to/cf-calls-matrix/client/patches/call-toggle-and-hangup.patch
```

## CI/CD

Three GitHub Actions workflows (see `.github/workflows/`):

| Workflow | Trigger | Action |
|----------|---------|--------|
| `deploy-server.yml` | Push to `main` (server files) | Deploy server Worker |
| `deploy-client.yml` | Push to `main` (`client/` files) | Build + deploy Element Web client |
| `release-client.yml` | Tag push (`v*`) | Build client, attach tarball to GitHub Release |

**Required GitHub secrets:**
- `CLOUDFLARE_API_TOKEN` — API token with Workers, D1, KV, R2 write permissions
- `CLOUDFLARE_ACCOUNT_ID` — Your Cloudflare account ID
- `WRANGLER_JSONC` — base64-encoded `wrangler.jsonc`: `base64 -i wrangler.jsonc | tr -d '\n'`
- `CLIENT_CONFIG_JSON` — base64-encoded `client/config.json`
- `CLIENT_WRANGLER_TOML` — base64-encoded `client/wrangler.toml`

## Git Commit Rules

- Never include Claude attribution (e.g., `Co-Authored-By`) in commit messages.

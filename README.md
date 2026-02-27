# cf-calls-matrix

[![Deploy Server](https://github.com/cf-remi/cf-calls-matrix/actions/workflows/deploy-server.yml/badge.svg)](https://github.com/cf-remi/cf-calls-matrix/actions/workflows/deploy-server.yml)
[![Deploy Client](https://github.com/cf-remi/cf-calls-matrix/actions/workflows/deploy-client.yml/badge.svg)](https://github.com/cf-remi/cf-calls-matrix/actions/workflows/deploy-client.yml)
[![Security](https://github.com/cf-remi/cf-calls-matrix/actions/workflows/security.yml/badge.svg)](https://github.com/cf-remi/cf-calls-matrix/actions/workflows/security.yml)

A self-hostable Matrix homeserver + Element Web client that runs entirely on **Cloudflare Workers** — no VPS, no containers, no infrastructure to manage.

- **Matrix server** — spec v1.17, runs on Workers + D1 + KV + R2 + Durable Objects
- **Element Web client** — patched v1.12.11, deployed as a Worker with Static Assets
- **One command setup** — `./setup.sh` provisions all Cloudflare resources and deploys both

**Live demo:** `matrix.goodshab.com` (server) · `goodshab.com` (client)

---

## Quick Start

```bash
git clone https://github.com/cf-remi/cf-calls-matrix
cd cf-calls-matrix
./setup.sh
```

The setup script will:
1. Check prerequisites (Node.js, wrangler, Cloudflare auth)
2. Ask for your domain, brand name, and account ID
3. Create all Cloudflare resources (D1, KV ×6, R2)
4. Generate `wrangler.jsonc` and `client/config.json` from templates
5. Run all 16 database migrations
6. Optionally configure secrets (TURN, Calls, APNS, OIDC)
7. Deploy the Matrix server Worker
8. Optionally build and deploy the Element Web client (~5 min)

**See [DEPLOYMENT.md](./DEPLOYMENT.md) for the complete manual setup guide.**

---

## Prerequisites

- **Cloudflare account** with [Workers Paid plan](https://developers.cloudflare.com/workers/platform/pricing/) ($5/month — required for Durable Objects)
- **A domain managed by Cloudflare DNS** (required for federation)
- **Node.js 18+** and **wrangler** CLI (`npm install -g wrangler`)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Cloudflare Edge Network                           │
├─────────────────────────────────────────────────────────────────────────────┤
│  yourdomain.com                    matrix.yourdomain.com                    │
│  ┌──────────────────────┐          ┌──────────────────────────────────────┐ │
│  │   Element Web        │          │   Matrix Server Worker (Hono)        │ │
│  │   Worker + Static    │          │                                      │ │
│  │   Assets             │  HTTPS   │  ┌──────────┐  ┌──────────────────┐ │ │
│  │                      │◄────────►│  │ Durable  │  │  D1 (SQLite)     │ │ │
│  │  • SPA routing       │          │  │ Objects  │  │  users/rooms/    │ │ │
│  │  • Static files      │          │  │ Room/Sync│  │  events/keys     │ │ │
│  │  • config.json       │          │  │ /Fed/Keys│  └──────────────────┘ │ │
│  └──────────────────────┘          │  └──────────┘                        │ │
│                                    │  ┌──────────┐  ┌──────────────────┐ │ │
│                                    │  │ KV (×6)  │  │  R2 (media)      │ │ │
│                                    │  │ sessions │  │  images/files    │ │ │
│                                    │  │ keys/cache│  │  avatars         │ │ │
│                                    │  └──────────┘  └──────────────────┘ │ │
│                                    │  ┌─────────────────────────────────┐ │ │
│                                    │  │ Workflows (durable execution)   │ │ │
│                                    │  │ RoomJoin · PushNotification     │ │ │
│                                    │  └─────────────────────────────────┘ │ │
│                                    └──────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Features

**Matrix Server**
- Full Matrix spec v1.17 compliance (Client-Server + Server-Server APIs)
- End-to-end encryption (device keys, cross-signing, key backup, OTKs)
- Sliding Sync (MSC3575/MSC4186) for Element X / fast clients
- Federation with standard Matrix servers
- Media upload/download with R2 storage (MSC3916 authenticated media)
- Push notifications (APNs direct, FCM via gateway)
- Video calling: Cloudflare Calls SFU + LiveKit MatrixRTC
- OIDC / OAuth 2.0 login (MSC3861)
- Admin dashboard at `/admin`
- Rate limiting via Durable Objects

**Element Web Client**
- Patched element-web v1.12.11
- Call view toggle: video button shows/hides the call rather than opening duplicates
- Clean hangup: hanging up returns to room timeline, not the post-hangup lobby
- Deployed as a Cloudflare Worker with Static Assets (no per-deployment preview URLs)

---

## Spec Compliance

**[Matrix Specification v1.17](https://spec.matrix.org/v1.17/)**

| Spec Section | Implementation |
|---|---|
| [Client-Server API](https://spec.matrix.org/v1.17/client-server-api/) | `src/api/` — Auth, sync, rooms, messaging, profiles |
| [Server-Server API](https://spec.matrix.org/v1.17/server-server-api/) | `src/api/federation.ts` |
| [End-to-End Encryption](https://spec.matrix.org/v1.17/client-server-api/#end-to-end-encryption) | `src/api/keys.ts`, `src/api/key-backups.ts` |
| [OAuth 2.0 / OIDC](https://spec.matrix.org/v1.17/client-server-api/#oauth-20-api) | `src/api/oauth.ts`, `src/api/oidc-auth.ts` (MSC3861) |
| [Sliding Sync](https://github.com/matrix-org/matrix-spec-proposals/pull/3575) | `src/api/sliding-sync.ts` (MSC3575, MSC4186) |
| [Authenticated Media](https://github.com/matrix-org/matrix-spec-proposals/pull/3916) | `src/api/media.ts` (MSC3916) |
| [Push Notifications](https://spec.matrix.org/v1.17/client-server-api/#push-notifications) | `src/api/push.ts`, `src/workflows/` |
| [VoIP / MatrixRTC](https://spec.matrix.org/v1.17/client-server-api/#voice-over-ip) | `src/api/voip.ts`, `src/api/calls.ts` |

---

## Cloudflare Bindings

| Binding | Type | Purpose |
|---|---|---|
| `DB` | D1 | Users, rooms, events, access tokens |
| `SESSIONS` | KV | Access/refresh token lookups (with TTL) |
| `DEVICE_KEYS` | KV | E2EE device keys |
| `ONE_TIME_KEYS` | KV | Olm prekeys |
| `CROSS_SIGNING_KEYS` | KV | Cross-signing keys |
| `CACHE` | KV | Presence, federation txns, sync filters |
| `ACCOUNT_DATA` | KV | Per-user account settings |
| `MEDIA` | R2 | Media file storage |
| `ROOMS` | Durable Object | Room coordination, WebSocket |
| `SYNC` | Durable Object | Sync state management |
| `FEDERATION` | Durable Object | Federation queue |
| `CALL_ROOMS` | Durable Object | Video call room coordination |
| `USER_KEYS` | Durable Object | E2EE key operations |
| `PUSH` | Durable Object | Push notification queue |
| `ADMIN` | Durable Object | Admin operations |
| `RATE_LIMIT` | Durable Object | Sliding-window rate limiting |
| `ROOM_JOIN_WORKFLOW` | Workflow | Async room join / federation handshake |
| `PUSH_NOTIFICATION_WORKFLOW` | Workflow | Async push delivery |

---

## Development

```bash
npm install
npm run dev       # Local dev server
npm run typecheck # TypeScript check
npm run test      # Vitest
```

---

## Compatibility

Tested with Element Web (this repo's patched build), Element X iOS, and Element X Android.
Federation tested with matrix.org via the [Matrix Federation Tester](https://federationtester.matrix.org).

---

## Limitations

| Constraint | Limit |
|---|---|
| Worker CPU | 30s (use Workflows for long ops) |
| D1 Database | 10GB |
| R2 Object | 5GB (chunked upload supported) |
| KV Value | 25MB |

---

## License

MIT

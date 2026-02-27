# Deployment Guide

Complete guide to deploying your own Matrix homeserver + Element Web client on Cloudflare Workers.

## Table of Contents

- [Quick Start (setup.sh)](#quick-start)
- [Manual Deployment](#manual-deployment)
  - [Prerequisites](#prerequisites)
  - [1. Clone and install](#1-clone-and-install)
  - [2. Create Cloudflare resources](#2-create-cloudflare-resources)
  - [3. Generate config files](#3-generate-config-files)
  - [4. Run database migrations](#4-run-database-migrations)
  - [5. Set secrets (optional)](#5-set-secrets-optional)
  - [6. Deploy the server](#6-deploy-the-server)
  - [7. Deploy the client](#7-deploy-the-client)
  - [8. Verify](#8-verify)
- [CI/CD with GitHub Actions](#cicd-with-github-actions)
- [Optional features](#optional-features)
- [Updating](#updating)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

The fastest way to deploy is the interactive setup script:

```bash
git clone https://github.com/cf-remi/cf-calls-matrix
cd cf-calls-matrix
./setup.sh
```

The script handles everything: resource creation, config generation, migrations, and deployment.
Skip to [Verify](#8-verify) once it finishes.

---

## Manual Deployment

Use this if you want full control, or if `setup.sh` fails partway through.

### Prerequisites

1. **Cloudflare account** with Workers Paid plan ($5/month — required for Durable Objects)
2. **A domain managed by Cloudflare DNS** (federation requires a real domain)
3. **Node.js 18+**: `node --version`
4. **wrangler CLI**: `npm install -g wrangler && wrangler login`

---

### 1. Clone and install

```bash
git clone https://github.com/cf-remi/cf-calls-matrix
cd cf-calls-matrix
npm install
```

---

### 2. Create Cloudflare resources

Save the IDs from each command's output — you'll need them in step 3.

#### Get your account ID
```bash
wrangler whoami
```

#### Create D1 database
```bash
wrangler d1 create my-matrix-db
# Save: database_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

#### Create KV namespaces (6 required)
```bash
wrangler kv namespace create SESSIONS
wrangler kv namespace create DEVICE_KEYS
wrangler kv namespace create CACHE
wrangler kv namespace create CROSS_SIGNING_KEYS
wrangler kv namespace create ACCOUNT_DATA
wrangler kv namespace create ONE_TIME_KEYS
# Save all 6 IDs (id = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
```

#### Create R2 bucket
```bash
wrangler r2 bucket create my-matrix-media
```

---

### 3. Generate config files

Copy the templates and fill in your values:

#### Server config (`wrangler.jsonc`)
```bash
cp wrangler.jsonc.template wrangler.jsonc
```

Edit `wrangler.jsonc` — replace all `{{PLACEHOLDER}}` values:

| Placeholder | Value |
|---|---|
| `{{ACCOUNT_ID}}` | Your Cloudflare account ID |
| `{{WORKER_NAME}}` | e.g. `my-matrix` |
| `{{D1_DATABASE_NAME}}` | e.g. `my-matrix-db` |
| `{{D1_DATABASE_ID}}` | UUID from `d1 create` |
| `{{KV_SESSIONS_ID}}` | ID from `kv namespace create SESSIONS` |
| `{{KV_DEVICE_KEYS_ID}}` | ID from `kv namespace create DEVICE_KEYS` |
| `{{KV_CACHE_ID}}` | ID from `kv namespace create CACHE` |
| `{{KV_CROSS_SIGNING_KEYS_ID}}` | ID from `kv namespace create CROSS_SIGNING_KEYS` |
| `{{KV_ACCOUNT_DATA_ID}}` | ID from `kv namespace create ACCOUNT_DATA` |
| `{{KV_ONE_TIME_KEYS_ID}}` | ID from `kv namespace create ONE_TIME_KEYS` |
| `{{R2_BUCKET_NAME}}` | e.g. `my-matrix-media` |
| `{{SERVER_NAME}}` | e.g. `matrix.yourdomain.com` |

> **Important:** `SERVER_NAME` cannot be changed after users register. Choose carefully.

#### Client config (`client/config.json`)
```bash
cp client/config.json.template client/config.json
```

Edit `client/config.json` — replace:
- `{{SERVER_NAME}}` → `matrix.yourdomain.com`
- `{{BRAND}}` → Your app name (e.g. `MyChat`)

#### Client wrangler config (`client/wrangler.toml`)
```bash
cp client/wrangler.toml.template client/wrangler.toml
```

Edit `client/wrangler.toml` — replace:
- `{{ACCOUNT_ID}}` → Your Cloudflare account ID
- `{{WORKER_NAME}}` → e.g. `my` (becomes `my-element`)
- `{{CLIENT_DOMAIN}}` → e.g. `yourdomain.com`

---

### 4. Run database migrations

Apply all 16 migrations in order (replace `my-matrix-db` with your actual database name):

```bash
wrangler d1 execute my-matrix-db --remote --file=migrations/schema.sql
wrangler d1 execute my-matrix-db --remote --file=migrations/002_phase1_e2ee.sql
wrangler d1 execute my-matrix-db --remote --file=migrations/003_account_management.sql
wrangler d1 execute my-matrix-db --remote --file=migrations/004_reports_and_notices.sql
# Note: two migrations share the 005 prefix — both must be run
wrangler d1 execute my-matrix-db --remote --file=migrations/005_server_config.sql
wrangler d1 execute my-matrix-db --remote --file=migrations/005_idp_providers.sql
wrangler d1 execute my-matrix-db --remote --file=migrations/006_query_optimization.sql
wrangler d1 execute my-matrix-db --remote --file=migrations/007_secure_server_keys.sql
wrangler d1 execute my-matrix-db --remote --file=migrations/008_federation_transactions.sql
wrangler d1 execute my-matrix-db --remote --file=migrations/009_reports_extended.sql
wrangler d1 execute my-matrix-db --remote --file=migrations/010_fix_reports_schema.sql
wrangler d1 execute my-matrix-db --remote --file=migrations/011_identity_service.sql
wrangler d1 execute my-matrix-db --remote --file=migrations/012_fts_search.sql
wrangler d1 execute my-matrix-db --remote --file=migrations/013_remote_device_lists.sql
wrangler d1 execute my-matrix-db --remote --file=migrations/014_appservice.sql
wrangler d1 execute my-matrix-db --remote --file=migrations/015_identity_associations.sql
```

Each migration should complete with `"success": true`.

---

### 5. Set secrets (optional)

Secrets are required for some features. Set them with `wrangler secret put <NAME>`.

#### Voice/video calls (Cloudflare Calls)
```bash
wrangler secret put TURN_API_TOKEN     # From dash.cloudflare.com → Calls → TURN
wrangler secret put CALLS_APP_SECRET   # From dash.cloudflare.com → Calls
```

#### LiveKit (MatrixRTC alternative)
```bash
wrangler secret put LIVEKIT_API_SECRET
```

#### Apple Push Notifications (iOS)
```bash
wrangler secret put APNS_KEY_ID        # From Apple Developer Portal → Keys
wrangler secret put APNS_TEAM_ID       # From Apple Developer Portal → Membership
wrangler secret put APNS_PRIVATE_KEY   # Full contents of your .p8 key file
```

#### OIDC login
```bash
wrangler secret put OIDC_ENCRYPTION_KEY  # openssl rand -base64 32
```

#### Email verification
```bash
wrangler secret put EMAIL_FROM  # e.g. noreply@yourdomain.com
```

---

### 6. Deploy the server

```bash
npm run deploy
# or: wrangler deploy
```

The Worker is deployed and the custom domain `matrix.yourdomain.com` is provisioned automatically (requires the domain to be on Cloudflare DNS).

---

### 7. Deploy the client

#### Option A: Build from source (~5 minutes)

```bash
bash client/build.sh
cd client/dist && wrangler deploy
```

`build.sh` clones element-web v1.12.11, applies the patches in `client/patches/`, builds it, and outputs to `client/dist/`.

#### Option B: Download pre-built release (faster)

Download the latest `element-web-cf-calls-matrix.tar.gz` from [GitHub Releases](https://github.com/cf-remi/cf-calls-matrix/releases).

```bash
mkdir -p client/dist
tar -xzf element-web-cf-calls-matrix.tar.gz -C client/dist/

# Copy your config and deployment files
cp client/config.json      client/dist/config.json
cp client/worker.js        client/dist/worker.js
cp client/wrangler.toml    client/dist/wrangler.toml
cp client/.assetsignore    client/dist/.assetsignore
cp -r client/.well-known   client/dist/.well-known

cd client/dist && wrangler deploy
```

---

### 8. Verify

```bash
export SERVER="https://matrix.yourdomain.com"

# Check server is responding
curl -s "$SERVER/_matrix/client/versions" | jq .

# Check .well-known
curl -s "$SERVER/.well-known/matrix/server" | jq .
curl -s "$SERVER/.well-known/matrix/client" | jq .

# Check federation keys
curl -s "$SERVER/_matrix/key/v2/server" | jq .
```

Run the [Federation Tester](https://federationtester.matrix.org) with your server name.

#### Register your first user
```bash
curl -X POST "$SERVER/_matrix/client/v3/register" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"your-password","auth":{"type":"m.login.dummy"}}'
```

#### Access admin dashboard
Open `https://matrix.yourdomain.com/admin` in your browser.

---

## CI/CD with GitHub Actions

Three workflows are included:

| Workflow | File | Trigger |
|---|---|---|
| Deploy server | `.github/workflows/deploy-server.yml` | Push to `main` (server files) |
| Deploy client | `.github/workflows/deploy-client.yml` | Push to `main` (`client/` files) |
| Release client | `.github/workflows/release-client.yml` | Tag push `v*` or manual dispatch |

### Required GitHub secrets

Go to your fork → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | How to generate |
|---|---|
| `CLOUDFLARE_API_TOKEN` | [Create API token](https://dash.cloudflare.com/profile/api-tokens) with Workers, D1, KV, R2 Write permissions |
| `CLOUDFLARE_ACCOUNT_ID` | From `wrangler whoami` |
| `WRANGLER_JSONC` | `base64 -i wrangler.jsonc \| tr -d '\n'` |
| `CLIENT_CONFIG_JSON` | `base64 -i client/config.json \| tr -d '\n'` |
| `CLIENT_WRANGLER_TOML` | `base64 -i client/wrangler.toml \| tr -d '\n'` |

Once set, pushes to `main` will automatically deploy the affected Worker.

---

## Optional features

### TURN / Cloudflare Calls (voice/video)

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com) → **Calls**
2. Create a TURN key and a Calls app
3. Add to `wrangler.jsonc` under `vars`:
   ```jsonc
   "TURN_KEY_ID": "your-turn-key-id",
   "CALLS_APP_ID": "your-calls-app-id"
   ```
4. Set secrets: `wrangler secret put TURN_API_TOKEN` and `wrangler secret put CALLS_APP_SECRET`

### LiveKit (MatrixRTC)

1. Add to `wrangler.jsonc` under `vars`:
   ```jsonc
   "LIVEKIT_API_KEY": "your-api-key",
   "LIVEKIT_URL": "wss://your-livekit-server.com"
   ```
2. Set secret: `wrangler secret put LIVEKIT_API_SECRET`

---

## Updating

```bash
git pull
npm install
npm run deploy
```

If there are new migration files, run them before deploying:

```bash
wrangler d1 execute my-matrix-db --remote --file=migrations/NEW_MIGRATION.sql
```

---

## Troubleshooting

### "Workers Paid plan required"
Durable Objects require the Workers Paid plan ($5/month).
Upgrade at: Cloudflare Dashboard → Workers & Pages → Plans.

### Database not found
Ensure the `database_name` in `wrangler.jsonc` exactly matches the name used in `d1 create`.

### Federation test fails
1. Verify your domain's DNS is managed by Cloudflare
2. Check `.well-known/matrix/server` returns correct content
3. The Worker auto-generates a signing key on first request — federation tests before the first request may fail

### Errors in production
```bash
wrangler tail  # Stream live logs
```

### Registration disabled
Enable/disable registration from the admin dashboard at `/admin` → Settings.

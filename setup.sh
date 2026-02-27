#!/usr/bin/env bash
# setup.sh — Interactive setup for cf-calls-matrix
# Deploys a complete Matrix homeserver + Element Web client on Cloudflare Workers.
#
# Usage: ./setup.sh
#
# What this script does:
#   1. Checks prerequisites (node, wrangler, auth)
#   2. Prompts for your domain, brand name, and Cloudflare account ID
#   3. Creates all required Cloudflare resources (D1, KV, R2)
#   4. Generates wrangler.jsonc and client config files from templates
#   5. Runs all D1 database migrations
#   6. Optionally sets secrets (TURN, Calls, APNS, OIDC, Email)
#   7. Deploys the server Worker
#   8. Optionally builds and deploys the Element Web client

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

log()    { echo -e "${BLUE}-->${RESET} $*"; }
ok()     { echo -e "${GREEN}✓${RESET}  $*"; }
warn()   { echo -e "${YELLOW}!${RESET}  $*"; }
error()  { echo -e "${RED}✗${RESET}  $*" >&2; }
header() { echo -e "\n${BOLD}$*${RESET}"; }
ask()    { echo -e "${YELLOW}?${RESET}  $*"; }

# ─── Prerequisites ───────────────────────────────────────────────────────────
check_prerequisites() {
  header "Step 1: Checking prerequisites"

  # Node.js
  if ! command -v node &>/dev/null; then
    error "Node.js is not installed. Install from https://nodejs.org (v18+)"
    exit 1
  fi
  NODE_VERSION=$(node --version | sed 's/v//' | cut -d. -f1)
  if [ "${NODE_VERSION}" -lt 18 ]; then
    error "Node.js v18+ required (found $(node --version))"
    exit 1
  fi
  ok "Node.js $(node --version)"

  # wrangler
  if ! command -v wrangler &>/dev/null && ! npx --no wrangler --version &>/dev/null 2>&1; then
    warn "wrangler not found. Installing globally..."
    npm install -g wrangler
  fi
  WRANGLER_CMD="wrangler"
  if ! command -v wrangler &>/dev/null; then
    WRANGLER_CMD="npx wrangler"
  fi
  ok "wrangler $($WRANGLER_CMD --version 2>&1 | head -1)"

  # wrangler auth
  log "Checking Cloudflare authentication..."
  if ! $WRANGLER_CMD whoami &>/dev/null 2>&1; then
    warn "Not authenticated. Opening browser for Cloudflare login..."
    $WRANGLER_CMD login
  fi
  ok "Authenticated with Cloudflare"
}

# ─── Configuration ───────────────────────────────────────────────────────────
gather_config() {
  header "Step 2: Configuration"

  echo ""
  echo "  This will deploy:"
  echo "    - Matrix homeserver  →  matrix.yourdomain.com"
  echo "    - Element Web client →  yourdomain.com"
  echo ""
  echo "  Your domain must already be added to Cloudflare DNS."
  echo ""

  # Account ID
  DETECTED_ACCOUNT_ID=$($WRANGLER_CMD whoami 2>&1 | grep -oE '[0-9a-f]{32}' | head -1 || true)
  if [ -n "${DETECTED_ACCOUNT_ID}" ]; then
    ask "Cloudflare Account ID [${DETECTED_ACCOUNT_ID}]:"
    read -r INPUT_ACCOUNT_ID
    ACCOUNT_ID="${INPUT_ACCOUNT_ID:-${DETECTED_ACCOUNT_ID}}"
  else
    ask "Cloudflare Account ID (from dash.cloudflare.com → top-right menu):"
    read -r ACCOUNT_ID
    if [ -z "${ACCOUNT_ID}" ]; then
      error "Account ID is required."
      exit 1
    fi
  fi

  # Domain
  ask "Your domain (e.g. example.com — Matrix will be at matrix.example.com):"
  read -r DOMAIN
  if [ -z "${DOMAIN}" ]; then
    error "Domain is required."
    exit 1
  fi
  # Strip leading protocol if someone pastes a URL
  DOMAIN="${DOMAIN#https://}"
  DOMAIN="${DOMAIN#http://}"
  DOMAIN="${DOMAIN%/}"
  SERVER_NAME="matrix.${DOMAIN}"
  CLIENT_DOMAIN="${DOMAIN}"

  # Brand name
  ask "Brand name for the chat client (e.g. MyChat) [cf-calls-matrix]:"
  read -r BRAND
  BRAND="${BRAND:-cf-calls-matrix}"

  # Worker name prefix
  SUGGESTED_PREFIX=$(echo "${DOMAIN}" | sed 's/\./-/g')
  ask "Worker name prefix (used for resource names) [${SUGGESTED_PREFIX}]:"
  read -r PREFIX
  PREFIX="${PREFIX:-${SUGGESTED_PREFIX}}"

  WORKER_NAME="${PREFIX}-matrix"
  D1_DATABASE_NAME="${PREFIX}-matrix-db"
  R2_BUCKET_NAME="${PREFIX}-matrix-media"

  echo ""
  echo "  Configuration summary:"
  echo "    Account ID   : ${ACCOUNT_ID}"
  echo "    Server domain: ${SERVER_NAME}"
  echo "    Client domain: ${CLIENT_DOMAIN}"
  echo "    Brand        : ${BRAND}"
  echo "    Worker name  : ${WORKER_NAME}"
  echo "    D1 database  : ${D1_DATABASE_NAME}"
  echo "    R2 bucket    : ${R2_BUCKET_NAME}"
  echo ""
  ask "Proceed? (y/n) [y]:"
  read -r CONFIRM
  CONFIRM="${CONFIRM:-y}"
  if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
}

# ─── Create Cloudflare resources ─────────────────────────────────────────────
create_resources() {
  header "Step 3: Creating Cloudflare resources"

  # D1 Database
  log "Creating D1 database '${D1_DATABASE_NAME}'..."
  D1_OUTPUT=$($WRANGLER_CMD d1 create "${D1_DATABASE_NAME}" 2>&1)
  D1_DATABASE_ID=$(echo "${D1_OUTPUT}" | grep -oE 'database_id\s*=\s*"[^"]+"' | grep -oE '[0-9a-f-]{36}' || true)
  if [ -z "${D1_DATABASE_ID}" ]; then
    # Already exists — try to get the ID
    warn "D1 database may already exist. Fetching ID..."
    D1_DATABASE_ID=$($WRANGLER_CMD d1 list 2>&1 | grep "${D1_DATABASE_NAME}" | grep -oE '[0-9a-f-]{36}' | head -1 || true)
  fi
  if [ -z "${D1_DATABASE_ID}" ]; then
    error "Could not determine D1 database ID. Check output:\n${D1_OUTPUT}"
    exit 1
  fi
  ok "D1: ${D1_DATABASE_NAME} (${D1_DATABASE_ID})"

  # KV Namespaces
  create_kv() {
    local BINDING="$1"
    local OUTPUT
    OUTPUT=$($WRANGLER_CMD kv namespace create "${BINDING}" 2>&1)
    local ID
    ID=$(echo "${OUTPUT}" | grep -oE '"id"\s*:\s*"[^"]+"' | grep -oE '"[0-9a-f]{32}"' | tr -d '"' || true)
    if [ -z "${ID}" ]; then
      # Try alternate output format
      ID=$(echo "${OUTPUT}" | grep -oE 'id = "[^"]+"' | grep -oE '[0-9a-f]{32}' || true)
    fi
    if [ -z "${ID}" ]; then
      warn "KV ${BINDING} may already exist. Fetching ID..."
      ID=$($WRANGLER_CMD kv namespace list 2>&1 | python3 -c "
import sys, json
data = json.load(sys.stdin)
for ns in data:
    if ns.get('title','').endswith('${BINDING}'):
        print(ns['id'])
        break
" 2>/dev/null || true)
    fi
    echo "${ID}"
  }

  log "Creating KV namespaces (6)..."
  KV_SESSIONS_ID=$(create_kv "SESSIONS");         ok "KV: SESSIONS (${KV_SESSIONS_ID})"
  KV_DEVICE_KEYS_ID=$(create_kv "DEVICE_KEYS");   ok "KV: DEVICE_KEYS (${KV_DEVICE_KEYS_ID})"
  KV_CACHE_ID=$(create_kv "CACHE");               ok "KV: CACHE (${KV_CACHE_ID})"
  KV_CROSS_SIGNING_KEYS_ID=$(create_kv "CROSS_SIGNING_KEYS"); ok "KV: CROSS_SIGNING_KEYS (${KV_CROSS_SIGNING_KEYS_ID})"
  KV_ACCOUNT_DATA_ID=$(create_kv "ACCOUNT_DATA"); ok "KV: ACCOUNT_DATA (${KV_ACCOUNT_DATA_ID})"
  KV_ONE_TIME_KEYS_ID=$(create_kv "ONE_TIME_KEYS"); ok "KV: ONE_TIME_KEYS (${KV_ONE_TIME_KEYS_ID})"

  # R2 Bucket
  log "Creating R2 bucket '${R2_BUCKET_NAME}'..."
  $WRANGLER_CMD r2 bucket create "${R2_BUCKET_NAME}" 2>&1 || warn "R2 bucket may already exist, continuing..."
  ok "R2: ${R2_BUCKET_NAME}"
}

# ─── Generate config files from templates ────────────────────────────────────
generate_configs() {
  header "Step 4: Generating configuration files"

  # Server wrangler.jsonc
  log "Writing wrangler.jsonc..."
  sed \
    -e "s/{{ACCOUNT_ID}}/${ACCOUNT_ID}/g" \
    -e "s/{{WORKER_NAME}}/${WORKER_NAME}/g" \
    -e "s/{{D1_DATABASE_NAME}}/${D1_DATABASE_NAME}/g" \
    -e "s/{{D1_DATABASE_ID}}/${D1_DATABASE_ID}/g" \
    -e "s/{{KV_SESSIONS_ID}}/${KV_SESSIONS_ID}/g" \
    -e "s/{{KV_DEVICE_KEYS_ID}}/${KV_DEVICE_KEYS_ID}/g" \
    -e "s/{{KV_CACHE_ID}}/${KV_CACHE_ID}/g" \
    -e "s/{{KV_CROSS_SIGNING_KEYS_ID}}/${KV_CROSS_SIGNING_KEYS_ID}/g" \
    -e "s/{{KV_ACCOUNT_DATA_ID}}/${KV_ACCOUNT_DATA_ID}/g" \
    -e "s/{{KV_ONE_TIME_KEYS_ID}}/${KV_ONE_TIME_KEYS_ID}/g" \
    -e "s/{{R2_BUCKET_NAME}}/${R2_BUCKET_NAME}/g" \
    -e "s/{{SERVER_NAME}}/${SERVER_NAME}/g" \
    "${SCRIPT_DIR}/wrangler.jsonc.template" > "${SCRIPT_DIR}/wrangler.jsonc"
  ok "wrangler.jsonc"

  # Client config.json
  log "Writing client/config.json..."
  sed \
    -e "s/{{SERVER_NAME}}/${SERVER_NAME}/g" \
    -e "s/{{BRAND}}/${BRAND}/g" \
    "${SCRIPT_DIR}/client/config.json.template" > "${SCRIPT_DIR}/client/config.json"
  ok "client/config.json"

  # Client wrangler.toml
  log "Writing client/wrangler.toml..."
  sed \
    -e "s/{{ACCOUNT_ID}}/${ACCOUNT_ID}/g" \
    -e "s/{{WORKER_NAME}}/${PREFIX}/g" \
    -e "s/{{CLIENT_DOMAIN}}/${CLIENT_DOMAIN}/g" \
    "${SCRIPT_DIR}/client/wrangler.toml.template" > "${SCRIPT_DIR}/client/wrangler.toml"
  ok "client/wrangler.toml"
}

# ─── Run database migrations ─────────────────────────────────────────────────
run_migrations() {
  header "Step 5: Running database migrations"

  MIGRATIONS_DIR="${SCRIPT_DIR}/migrations"

  # Run schema.sql first, then numbered migrations in sorted order
  MIGRATION_FILES=("${MIGRATIONS_DIR}/schema.sql")
  while IFS= read -r -d '' f; do
    MIGRATION_FILES+=("$f")
  done < <(find "${MIGRATIONS_DIR}" -name '0*.sql' -print0 | sort -z)

  TOTAL=${#MIGRATION_FILES[@]}
  COUNT=0
  for MIGRATION in "${MIGRATION_FILES[@]}"; do
    COUNT=$((COUNT + 1))
    FILENAME=$(basename "${MIGRATION}")
    log "[${COUNT}/${TOTAL}] ${FILENAME}..."
    $WRANGLER_CMD d1 execute "${D1_DATABASE_NAME}" --remote --file="${MIGRATION}" 2>&1 \
      | grep -E '(success|error|Error)' || true
    ok "${FILENAME}"
  done
}

# ─── Optional secrets ─────────────────────────────────────────────────────────
configure_secrets() {
  header "Step 6: Optional secrets"

  echo ""
  echo "  Secrets are required for some features. You can skip these now"
  echo "  and set them later with: wrangler secret put <NAME>"
  echo ""

  set_secret_if_wanted() {
    local NAME="$1"
    local DESC="$2"
    local HINT="${3:-}"
    ask "Set ${NAME}? ${DESC} (y/n) [n]:"
    read -r WANT
    if [[ "${WANT}" == "y" || "${WANT}" == "Y" ]]; then
      if [ -n "${HINT}" ]; then
        echo "  Hint: ${HINT}"
      fi
      $WRANGLER_CMD secret put "${NAME}"
      ok "${NAME} set"
    fi
  }

  set_secret_if_wanted "TURN_API_TOKEN" \
    "(Cloudflare TURN for voice/video)" \
    "Generate at: dash.cloudflare.com → Calls → TURN"

  set_secret_if_wanted "CALLS_APP_SECRET" \
    "(Cloudflare Calls SFU for group video)" \
    "Generate at: dash.cloudflare.com → Calls"

  set_secret_if_wanted "LIVEKIT_API_SECRET" \
    "(LiveKit SFU for MatrixRTC, optional)" \
    ""

  set_secret_if_wanted "APNS_KEY_ID" \
    "(Apple Push Notifications — Key ID)" \
    "From Apple Developer Portal → Keys"

  set_secret_if_wanted "APNS_TEAM_ID" \
    "(Apple Push Notifications — Team ID)" \
    "From Apple Developer Portal → Membership"

  set_secret_if_wanted "APNS_PRIVATE_KEY" \
    "(Apple Push Notifications — .p8 key contents)" \
    "Paste the full contents of your .p8 file"

  set_secret_if_wanted "OIDC_ENCRYPTION_KEY" \
    "(OIDC login encryption key)" \
    "Generate with: openssl rand -base64 32"

  set_secret_if_wanted "EMAIL_FROM" \
    "(From address for verification emails)" \
    "e.g. noreply@${DOMAIN}"
}

# ��── Deploy server ───────────────────────────────────────────────────────────
deploy_server() {
  header "Step 7: Deploying Matrix server"

  log "Installing npm dependencies..."
  npm install --silent

  log "Deploying server Worker to ${SERVER_NAME}..."
  $WRANGLER_CMD deploy
  ok "Server deployed to https://${SERVER_NAME}"

  echo ""
  echo "  Verifying deployment..."
  sleep 3
  if curl -sf "https://${SERVER_NAME}/_matrix/client/versions" &>/dev/null; then
    ok "Server is responding at https://${SERVER_NAME}/_matrix/client/versions"
  else
    warn "Server deployed but not yet responding — DNS may still be propagating (wait ~30s)"
  fi
}

# ─── Deploy client ───────────────────────────────────────────────────────────
deploy_client() {
  header "Step 8: Element Web client"

  ask "Build and deploy the Element Web client? This takes ~5 minutes. (y/n) [y]:"
  read -r DEPLOY_CLIENT
  DEPLOY_CLIENT="${DEPLOY_CLIENT:-y}"

  if [[ "${DEPLOY_CLIENT}" != "y" && "${DEPLOY_CLIENT}" != "Y" ]]; then
    echo ""
    echo "  Skipped. To deploy the client later:"
    echo "    cd ${SCRIPT_DIR}"
    echo "    ./client/build.sh"
    echo "    cd client/dist && wrangler deploy"
    return
  fi

  log "Building Element Web (this takes ~5 minutes)..."
  bash "${SCRIPT_DIR}/client/build.sh"

  log "Deploying Element Web client to ${CLIENT_DOMAIN}..."
  pushd "${SCRIPT_DIR}/client/dist" > /dev/null
  $WRANGLER_CMD deploy
  popd > /dev/null
  ok "Client deployed to https://${CLIENT_DOMAIN}"
}

# ─── Summary ─────────────────────────────────────────────────────────────────
print_summary() {
  header "Setup complete!"

  echo ""
  echo "  Your Matrix stack is live:"
  echo ""
  echo "    Matrix server : https://${SERVER_NAME}"
  echo "    Element client: https://${CLIENT_DOMAIN}"
  echo "    Admin panel   : https://${SERVER_NAME}/admin"
  echo ""
  echo "  Next steps:"
  echo ""
  echo "  1. Register your first user:"
  echo "     curl -X POST https://${SERVER_NAME}/_matrix/client/v3/register \\"
  echo "       -H 'Content-Type: application/json' \\"
  echo "       -d '{\"username\":\"admin\",\"password\":\"yourpassword\",\"auth\":{\"type\":\"m.login.dummy\"}}'"
  echo ""
  echo "  2. Verify federation:"
  echo "     https://federationtester.matrix.org/#${SERVER_NAME}"
  echo ""
  echo "  3. Monitor logs:"
  echo "     wrangler tail"
  echo ""
  echo "  Generated config files (gitignored — keep safe):"
  echo "    wrangler.jsonc       — server config with your resource IDs"
  echo "    client/config.json   — Element Web config"
  echo "    client/wrangler.toml — client deployment config"
  echo ""
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${BOLD}cf-calls-matrix — Self-hosted Matrix on Cloudflare Workers${RESET}"
  echo "  https://github.com/cf-remi/cf-calls-matrix"
  echo ""

  check_prerequisites
  gather_config
  create_resources
  generate_configs
  run_migrations
  configure_secrets
  deploy_server
  deploy_client
  print_summary
}

main "$@"

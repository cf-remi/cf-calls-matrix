# ── Resource Identifiers ──────────────────────────────────────────────────────

output "d1_database_id" {
  description = "D1 database UUID."
  value       = cloudflare_d1_database.matrix_db.id
}

output "d1_database_name" {
  description = "D1 database name (used for migration commands)."
  value       = cloudflare_d1_database.matrix_db.name
}

output "r2_bucket_name" {
  description = "R2 media bucket name."
  value       = cloudflare_r2_bucket.media.name
}

output "server_worker_name" {
  description = "Server Worker script name."
  value       = cloudflare_workers_script.server.script_name
}

output "client_worker_name" {
  description = "Client Worker script name."
  value       = cloudflare_workers_script.client.script_name
}

output "calls_app_id" {
  description = "Cloudflare Calls SFU App ID."
  value       = cloudflare_calls_sfu_app.main.uid
}

output "turn_key_id" {
  description = "Cloudflare TURN key ID."
  value       = cloudflare_calls_turn_app.main.uid
}

# ── Base64-Encoded Configs (for GitHub Actions secrets) ───────────────────────

output "wrangler_jsonc_b64" {
  description = "Base64-encoded wrangler.jsonc — set as WRANGLER_JSONC GitHub secret."
  value       = base64encode(local_file.wrangler_jsonc.content)
  sensitive   = true
}

output "client_wrangler_toml_b64" {
  description = "Base64-encoded client/wrangler.toml — set as CLIENT_WRANGLER_TOML GitHub secret."
  value       = base64encode(local_file.client_wrangler_toml.content)
}

output "client_config_json_b64" {
  description = "Base64-encoded client/config.json — set as CLIENT_CONFIG_JSON GitHub secret."
  value       = base64encode(local_file.client_config_json.content)
}

# ── GitHub Secrets Helper ─────────────────────────────────────────────────────
#
# Run this output after `terraform apply` to push all required secrets into
# GitHub Actions. Requires the `gh` CLI authenticated to the repo.
#
#   terraform output -raw github_secrets_commands | bash

output "github_secrets_commands" {
  description = "Shell commands to push Terraform outputs into GitHub Actions secrets. Run: terraform output -raw github_secrets_commands | bash"
  sensitive   = true
  value       = <<-SHELL
    #!/usr/bin/env bash
    set -euo pipefail

    REPO="${var.worker_prefix}/cf-calls-matrix"

    echo "Setting GitHub Actions secrets for $REPO..."

    gh secret set WRANGLER_JSONC \
      --repo "$REPO" \
      --body "$(terraform output -raw wrangler_jsonc_b64)"

    gh secret set CLIENT_WRANGLER_TOML \
      --repo "$REPO" \
      --body "$(terraform output -raw client_wrangler_toml_b64)"

    gh secret set CLIENT_CONFIG_JSON \
      --repo "$REPO" \
      --body "$(terraform output -raw client_config_json_b64)"

    echo "Done. CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID must be set manually."
    echo "  gh secret set CLOUDFLARE_API_TOKEN --repo $REPO"
    echo "  gh secret set CLOUDFLARE_ACCOUNT_ID --repo $REPO --body '${var.account_id}'"
  SHELL
}

# ── D1 Migration Commands ─────────────────────────────────────────────────────
#
# Run these after `terraform apply` to apply all database migrations.
# Requires wrangler CLI authenticated locally.
#
#   terraform output -raw d1_migration_commands | bash

output "d1_migration_commands" {
  description = "Shell commands to apply all D1 migrations in order. Run: terraform output -raw d1_migration_commands | bash"
  value       = <<-SHELL
    #!/usr/bin/env bash
    set -euo pipefail

    DB="${cloudflare_d1_database.matrix_db.name}"

    echo "Applying D1 migrations for $DB..."

    MIGRATIONS=(
      migrations/schema.sql
      migrations/002_phase1_e2ee.sql
      migrations/003_account_management.sql
      migrations/004_reports_and_notices.sql
      migrations/005_server_config.sql
      migrations/005_idp_providers.sql
      migrations/006_query_optimization.sql
      migrations/007_secure_server_keys.sql
      migrations/008_federation_transactions.sql
      migrations/009_reports_extended.sql
      migrations/010_fix_reports_schema.sql
      migrations/011_identity_service.sql
      migrations/012_fts_search.sql
      migrations/013_remote_device_lists.sql
      migrations/014_appservice.sql
      migrations/015_identity_associations.sql
    )

    for f in "$${MIGRATIONS[@]}"; do
      echo "  Applying $f..."
      npx wrangler d1 execute "$DB" --remote --file="$f"
    done

    echo "All migrations applied."
  SHELL
}

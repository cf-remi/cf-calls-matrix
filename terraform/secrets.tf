# ── Worker Secrets ────────────────────────────────────────────────────────────
#
# In Cloudflare provider v5, Worker secrets are managed inline in the
# cloudflare_workers_script resource's `bindings` list using type = "secret_text".
# Terraform stores encrypted values in state (sensitive = true).
#
# All secret bindings are defined in server.tf alongside the other bindings.
#
# Secrets managed in server.tf bindings:
#   SIGNING_KEY          — Ed25519 federation signing key (optional — auto-generated if absent)
#   TURN_API_TOKEN       — Cloudflare TURN token (from cloudflare_calls_turn_app.main.key)
#   CALLS_APP_SECRET     — Cloudflare Calls secret (from cloudflare_calls_sfu_app.main.secret)
#   LIVEKIT_API_SECRET   — LiveKit API secret (optional)
#   APNS_KEY_ID          — Apple Push Notification Key ID (optional)
#   APNS_TEAM_ID         — Apple Developer Team ID (optional)
#   APNS_PRIVATE_KEY     — APNs .p8 private key (optional)
#   OIDC_ENCRYPTION_KEY  — OIDC client secret encryption key (optional)
#   EMAIL_FROM           — Email from address (optional)
#
# To rotate a secret, update the variable value in terraform.tfvars and run
# `terraform apply`. Terraform will update only the changed binding.

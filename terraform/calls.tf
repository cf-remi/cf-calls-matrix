# ── Cloudflare Calls (SFU + TURN) ─────────────────────────────────────────────
#
# These resources are created unconditionally — they are free to provision
# and the server code checks at runtime whether the credentials are set.
# The generated app IDs and secrets are injected as Worker secrets.

resource "cloudflare_calls_sfu_app" "main" {
  account_id = var.account_id
  name       = "${var.worker_prefix}-calls"
}

resource "cloudflare_calls_turn_app" "main" {
  account_id = var.account_id
  name       = "${var.worker_prefix}-turn"
}

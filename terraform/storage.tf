# ── D1 Database ───────────────────────────────────────────────────────────────

resource "cloudflare_d1_database" "matrix_db" {
  account_id = var.account_id
  name       = "${var.worker_prefix}-matrix-db"
}

# ── KV Namespaces ─────────────────────────────────────────────────────────────

resource "cloudflare_workers_kv_namespace" "sessions" {
  account_id = var.account_id
  title      = "${var.worker_prefix}-SESSIONS"
}

resource "cloudflare_workers_kv_namespace" "device_keys" {
  account_id = var.account_id
  title      = "${var.worker_prefix}-DEVICE_KEYS"
}

resource "cloudflare_workers_kv_namespace" "cache" {
  account_id = var.account_id
  title      = "${var.worker_prefix}-CACHE"
}

resource "cloudflare_workers_kv_namespace" "cross_signing_keys" {
  account_id = var.account_id
  title      = "${var.worker_prefix}-CROSS_SIGNING_KEYS"
}

resource "cloudflare_workers_kv_namespace" "account_data" {
  account_id = var.account_id
  title      = "${var.worker_prefix}-ACCOUNT_DATA"
}

resource "cloudflare_workers_kv_namespace" "one_time_keys" {
  account_id = var.account_id
  title      = "${var.worker_prefix}-ONE_TIME_KEYS"
}

# ── R2 Bucket ─────────────────────────────────────────────────────────────────

resource "cloudflare_r2_bucket" "media" {
  account_id = var.account_id
  name       = "${var.worker_prefix}-matrix-media"
  location   = "ENAM"
}

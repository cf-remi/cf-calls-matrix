# ── Generated Config Files ────────────────────────────────────────────────────
#
# Terraform writes the following files (gitignored) after `terraform apply`:
#
#   ../wrangler.jsonc          — Server worker config consumed by `wrangler deploy`
#   ../client/wrangler.toml   — Client worker config consumed by `wrangler deploy`
#   ../client/config.json     — Element Web runtime config
#
# These files contain real resource IDs (D1, KV, etc.) and should never be
# committed. They are listed in the root .gitignore.
#
# CI uses the base64-encoded versions of these files, available as Terraform
# outputs, to populate GitHub Actions secrets.

resource "local_file" "wrangler_jsonc" {
  filename        = var.wrangler_jsonc_output_path
  file_permission = "0600"

  content = templatefile("${path.module}/templates/wrangler.jsonc.tftpl", {
    worker_name              = local.server_worker_name
    account_id               = var.account_id
    d1_database_name         = cloudflare_d1_database.matrix_db.name
    d1_database_id           = cloudflare_d1_database.matrix_db.id
    kv_sessions_id           = cloudflare_workers_kv_namespace.sessions.id
    kv_device_keys_id        = cloudflare_workers_kv_namespace.device_keys.id
    kv_cache_id              = cloudflare_workers_kv_namespace.cache.id
    kv_cross_signing_keys_id = cloudflare_workers_kv_namespace.cross_signing_keys.id
    kv_account_data_id       = cloudflare_workers_kv_namespace.account_data.id
    kv_one_time_keys_id      = cloudflare_workers_kv_namespace.one_time_keys.id
    r2_bucket_name           = cloudflare_r2_bucket.media.name
    server_name              = var.server_name
    server_version           = var.server_version
    auto_join_rooms          = var.auto_join_rooms
  })
}

resource "local_file" "client_wrangler_toml" {
  filename        = var.client_wrangler_toml_output_path
  file_permission = "0600"

  content = templatefile("${path.module}/templates/client_wrangler.toml.tftpl", {
    worker_name   = local.client_worker_name
    account_id    = var.account_id
    client_domain = var.client_domain
  })
}

resource "local_file" "client_config_json" {
  filename        = var.client_config_json_output_path
  file_permission = "0600"

  content = templatefile("${path.module}/templates/client_config.json.tftpl", {
    server_name = var.server_name
    brand       = var.brand
  })
}

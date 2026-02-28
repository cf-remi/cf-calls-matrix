# ── Server Worker ─────────────────────────────────────────────────────────────
#
# Defines all bindings, environment variables, secrets, Durable Object
# migrations, and Workflow bindings for the Matrix homeserver Worker.
#
# NOTE: Terraform manages bindings and configuration. Actual code deployment
#       is handled by CI via `wrangler deploy`. The content block here is a
#       minimal placeholder that registers the Worker with Cloudflare so that
#       bindings exist before the first CI deploy.

locals {
  server_worker_name = "${var.worker_prefix}-matrix"

  # Apex domain derived from server_name for zone lookup.
  # e.g. "matrix.example.com" → "example.com"
  server_name_parts = split(".", var.server_name)
  apex_domain       = join(".", slice(local.server_name_parts, length(local.server_name_parts) - 2, length(local.server_name_parts)))
}

data "cloudflare_zone" "main" {
  filter = {
    account = { id = var.account_id }
    name    = local.apex_domain
  }
}

resource "cloudflare_workers_script" "server" {
  account_id  = var.account_id
  script_name = local.server_worker_name

  # Minimal placeholder — CI deploys the real bundle via `wrangler deploy`.
  content     = <<-JS
    export default {
      fetch() { return new Response("Deploying...", { status: 503 }); }
    };
  JS
  main_module = "placeholder.js"

  compatibility_date  = "2024-11-01"
  compatibility_flags = ["nodejs_compat"]

  observability = {
    enabled = true
  }

  # ── Durable Object migrations ────────────────────────────────────────────────
  # Applied in order at deploy time. The first deploy sets all 6 migration tags.
  migrations = {
    steps = [
      {
        new_sqlite_classes = ["RoomDurableObject", "SyncDurableObject", "FederationDurableObject"]
      },
      { new_classes = ["CallRoomDurableObject"] },
      { new_classes = ["AdminDurableObject"] },
      { new_classes = ["UserKeysDurableObject"] },
      { new_classes = ["PushDurableObject"] },
      { new_classes = ["RateLimitDurableObject"] },
    ]
    new_tag = "v6"
  }

  # ── Bindings ─────────────────────────────────────────────────────────────────
  # All bindings use a flat list with a `type` discriminator (provider v5 schema).

  bindings = concat(
    # D1 Database
    [{
      name = "DB"
      type = "d1"
      id   = cloudflare_d1_database.matrix_db.id
    }],

    # KV Namespaces
    [
      { name = "SESSIONS",           type = "kv_namespace", namespace_id = cloudflare_workers_kv_namespace.sessions.id },
      { name = "DEVICE_KEYS",        type = "kv_namespace", namespace_id = cloudflare_workers_kv_namespace.device_keys.id },
      { name = "CACHE",              type = "kv_namespace", namespace_id = cloudflare_workers_kv_namespace.cache.id },
      { name = "CROSS_SIGNING_KEYS", type = "kv_namespace", namespace_id = cloudflare_workers_kv_namespace.cross_signing_keys.id },
      { name = "ACCOUNT_DATA",       type = "kv_namespace", namespace_id = cloudflare_workers_kv_namespace.account_data.id },
      { name = "ONE_TIME_KEYS",      type = "kv_namespace", namespace_id = cloudflare_workers_kv_namespace.one_time_keys.id },
    ],

    # R2 Bucket
    [{
      name        = "MEDIA"
      type        = "r2_bucket"
      bucket_name = cloudflare_r2_bucket.media.name
    }],

    # Durable Objects
    [
      { name = "ROOMS",      type = "durable_object_namespace", class_name = "RoomDurableObject" },
      { name = "SYNC",       type = "durable_object_namespace", class_name = "SyncDurableObject" },
      { name = "FEDERATION", type = "durable_object_namespace", class_name = "FederationDurableObject" },
      { name = "CALL_ROOMS", type = "durable_object_namespace", class_name = "CallRoomDurableObject" },
      { name = "ADMIN",      type = "durable_object_namespace", class_name = "AdminDurableObject" },
      { name = "USER_KEYS",  type = "durable_object_namespace", class_name = "UserKeysDurableObject" },
      { name = "PUSH",       type = "durable_object_namespace", class_name = "PushDurableObject" },
      { name = "RATE_LIMIT", type = "durable_object_namespace", class_name = "RateLimitDurableObject" },
    ],

    # Workflows
    [
      { name = "ROOM_JOIN_WORKFLOW",          type = "workflow", workflow_name = "room-join-workflow",          class_name = "RoomJoinWorkflow",          script_name = local.server_worker_name },
      { name = "PUSH_NOTIFICATION_WORKFLOW",  type = "workflow", workflow_name = "push-notification-workflow",  class_name = "PushNotificationWorkflow",  script_name = local.server_worker_name },
    ],

    # Plain-text environment variables
    [
      { name = "SERVER_NAME",    type = "plain_text", text = var.server_name },
      { name = "SERVER_VERSION", type = "plain_text", text = var.server_version },
    ],

    # Optional plain-text vars (only included when non-empty)
    var.auto_join_rooms != "" ? [{ name = "AUTO_JOIN_ROOMS",      type = "plain_text", text = var.auto_join_rooms }] : [],
    var.admin_contact_email != "" ? [{ name = "ADMIN_CONTACT_EMAIL", type = "plain_text", text = var.admin_contact_email }] : [],
    var.admin_contact_mxid != "" ? [{ name = "ADMIN_CONTACT_MXID",  type = "plain_text", text = var.admin_contact_mxid }] : [],
    # Calls resources — IDs come from Terraform-managed cloudflare_calls_* resources
    [{ name = "TURN_KEY_ID",  type = "plain_text", text = cloudflare_calls_turn_app.main.uid }],
    [{ name = "CALLS_APP_ID", type = "plain_text", text = cloudflare_calls_sfu_app.main.uid }],
    var.livekit_url != "" ? [{ name = "LIVEKIT_URL",  type = "plain_text", text = var.livekit_url }] : [],
    var.livekit_api_key != "" ? [{ name = "LIVEKIT_API_KEY", type = "plain_text", text = var.livekit_api_key }] : [],
    var.apns_environment != "" ? [{ name = "APNS_ENVIRONMENT", type = "plain_text", text = var.apns_environment }] : [],

    # Secrets (sensitive — stored encrypted by Cloudflare)
    var.signing_key != "" ? [{ name = "SIGNING_KEY", type = "secret_text", text = var.signing_key }] : [],
    # Calls secrets — keys come directly from Terraform-managed resource outputs
    [{ name = "TURN_API_TOKEN",  type = "secret_text", text = cloudflare_calls_turn_app.main.key }],
    [{ name = "CALLS_APP_SECRET", type = "secret_text", text = cloudflare_calls_sfu_app.main.secret }],
    var.livekit_api_secret != "" ? [{ name = "LIVEKIT_API_SECRET", type = "secret_text", text = var.livekit_api_secret }] : [],
    var.apns_key_id != "" ? [{ name = "APNS_KEY_ID",      type = "secret_text", text = var.apns_key_id }] : [],
    var.apns_team_id != "" ? [{ name = "APNS_TEAM_ID",    type = "secret_text", text = var.apns_team_id }] : [],
    var.apns_private_key != "" ? [{ name = "APNS_PRIVATE_KEY", type = "secret_text", text = var.apns_private_key }] : [],
    var.oidc_encryption_key != "" ? [{ name = "OIDC_ENCRYPTION_KEY", type = "secret_text", text = var.oidc_encryption_key }] : [],
    var.email_from != "" ? [{ name = "EMAIL_FROM", type = "secret_text", text = var.email_from }] : [],
  )
}

# ── Custom Domain ─────────────────────────────────────────────────────────────

resource "cloudflare_workers_custom_domain" "server" {
  account_id = var.account_id
  hostname   = var.server_name
  service    = cloudflare_workers_script.server.script_name
  zone_id    = data.cloudflare_zone.main.id
}

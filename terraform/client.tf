# ── Client Worker (Element Web) ───────────────────────────────────────────────
#
# The client is a static-assets Worker serving the patched Element Web SPA.
# Terraform registers the Worker resource and custom domain.
# CI builds the Element Web bundle and deploys it via `wrangler deploy`.
#
# The client domain may be on a different apex than the server (e.g. server
# is matrix.example.com, client is example.com). We derive the zone from
# the client_domain variable.

locals {
  client_worker_name = "${var.worker_prefix}-element"

  client_domain_parts = split(".", var.client_domain)
  client_apex_domain  = join(".", slice(local.client_domain_parts, length(local.client_domain_parts) - 2, length(local.client_domain_parts)))

  # If client apex == server apex, reuse the same zone data source; otherwise look up separately.
  client_zone_id = local.client_apex_domain == local.apex_domain ? data.cloudflare_zone.main.id : data.cloudflare_zone.client[0].id
}

data "cloudflare_zone" "client" {
  # Only created when the client domain is on a different apex from the server.
  count = local.client_apex_domain != local.apex_domain ? 1 : 0

  filter = {
    account = { id = var.account_id }
    name    = local.client_apex_domain
  }
}

resource "cloudflare_workers_script" "client" {
  account_id  = var.account_id
  script_name = local.client_worker_name

  # Minimal placeholder — CI builds Element Web and deploys via `wrangler deploy`.
  content     = <<-JS
    export default {
      fetch() { return new Response("Deploying...", { status: 503 }); }
    };
  JS
  main_module = "placeholder.js"

  compatibility_date = "2026-02-27"

  # Static assets config — CI supplies the actual built files.
  # Setting not_found_handling here pre-configures the SPA routing behaviour.
  assets = {
    config = {
      not_found_handling = "single-page-application"
    }
  }
}

# ── Custom Domain ─────────────────────────────────────────────────────────────

resource "cloudflare_workers_custom_domain" "client" {
  account_id = var.account_id
  hostname   = var.client_domain
  service    = cloudflare_workers_script.client.script_name
  zone_id    = local.client_zone_id
}

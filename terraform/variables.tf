# ── Authentication ──────────────────────────────────────────────────────────

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Workers, D1, KV, R2 write permissions."
  type        = string
  sensitive   = true
}

variable "account_id" {
  description = "Cloudflare account ID."
  type        = string
}

# ��─ Naming / Domains ─────────────────────────────────────────────────────────

variable "worker_prefix" {
  description = "Short prefix used to name all resources (e.g. 'goodshab'). Must be lowercase alphanumeric + hyphens."
  type        = string
}

variable "server_name" {
  description = "Matrix server hostname (e.g. 'matrix.example.com'). Immutable after first user registers."
  type        = string
}

variable "client_domain" {
  description = "Domain where Element Web is served (e.g. 'example.com')."
  type        = string
}

variable "brand" {
  description = "Brand name shown in Element Web UI (e.g. 'MyChat')."
  type        = string
  default     = "Element"
}

# ── Server Configuration ─────────────────────────────────────────────────────

variable "server_version" {
  description = "Reported Matrix server version string."
  type        = string
  default     = "0.1.0"
}

variable "auto_join_rooms" {
  description = "Comma-separated room IDs or aliases to auto-join new users into on registration. Leave empty to disable."
  type        = string
  default     = ""
}

# ── Secrets ──────────────────────────────────────────────────────────────────
# All secret variables are marked sensitive = true.
# Empty string means "don't create this secret" (conditionally managed).

variable "signing_key" {
  description = "Ed25519 federation signing key (base64). Auto-generated on first request if left empty."
  type        = string
  sensitive   = true
  default     = ""
}

variable "livekit_api_key" {
  description = "LiveKit API key. Optional — for MatrixRTC via LiveKit SFU."
  type        = string
  default     = ""
}

variable "livekit_api_secret" {
  description = "LiveKit API secret."
  type        = string
  sensitive   = true
  default     = ""
}

variable "livekit_url" {
  description = "LiveKit WebSocket URL for clients (e.g. 'wss://livekit.example.com')."
  type        = string
  default     = ""
}

variable "apns_key_id" {
  description = "Apple Push Notification Key ID. Optional — for iOS push notifications."
  type        = string
  default     = ""
}

variable "apns_team_id" {
  description = "Apple Developer Team ID."
  type        = string
  default     = ""
}

variable "apns_private_key" {
  description = "Contents of the APNs .p8 private key file."
  type        = string
  sensitive   = true
  default     = ""
}

variable "apns_environment" {
  description = "APNs environment: 'production' or 'sandbox'."
  type        = string
  default     = "production"
  validation {
    condition     = contains(["production", "sandbox"], var.apns_environment)
    error_message = "apns_environment must be 'production' or 'sandbox'."
  }
}

variable "oidc_encryption_key" {
  description = "Encryption key for OIDC client secrets (base64, 32 bytes). Generate with: openssl rand -base64 32"
  type        = string
  sensitive   = true
  default     = ""
}

variable "email_from" {
  description = "From address for verification emails (e.g. 'noreply@matrix.example.com'). Optional."
  type        = string
  default     = ""
}

variable "admin_contact_email" {
  description = "Admin contact email exposed in /.well-known/matrix/support. Optional."
  type        = string
  default     = ""
}

variable "admin_contact_mxid" {
  description = "Admin Matrix ID (e.g. '@admin:matrix.example.com'). Optional."
  type        = string
  default     = ""
}

# ── Local Output Paths ────────────────────────────────────────────────────────
# Control where Terraform writes the generated config files.

variable "wrangler_jsonc_output_path" {
  description = "Path (relative to repo root) where Terraform writes the generated wrangler.jsonc."
  type        = string
  default     = "../wrangler.jsonc"
}

variable "client_wrangler_toml_output_path" {
  description = "Path (relative to repo root) where Terraform writes the generated client/wrangler.toml."
  type        = string
  default     = "../client/wrangler.toml"
}

variable "client_config_json_output_path" {
  description = "Path (relative to repo root) where Terraform writes the generated client/config.json."
  type        = string
  default     = "../client/config.json"
}

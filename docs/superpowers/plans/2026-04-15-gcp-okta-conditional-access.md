# GCP Okta Conditional Access Addon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable Terraform addon module at `addons/gcp/okta-conditional-access/` that enables Fleet's Okta mTLS conditional access on GCP by attaching a `ServerTLSPolicy` to the existing Application Load Balancer.

**Architecture:** The addon creates two GCP resources — a `google_certificate_manager_trust_config` holding the Fleet SCEP CA cert inline (no S3/GCS needed), and a `google_network_security_server_tls_policy` in `REJECT_INVALID` mode. It outputs the policy self-link, a cert-serial header string, and redirect rules — all wired into the existing LB module by the caller. The `byo-project` module is updated to accept and forward these new optional inputs.

**Tech Stack:** Terraform ≥ 1.11, `hashicorp/google` provider ≥ 6.35.0, `GoogleCloudPlatform/lb-http/google//modules/serverless_negs` ~> 12.0

---

## File Map

**Create:**
- `addons/gcp/okta-conditional-access/main.tf` — TrustConfig + ServerTLSPolicy resources
- `addons/gcp/okta-conditional-access/variables.tf` — module inputs
- `addons/gcp/okta-conditional-access/outputs.tf` — server_tls_policy self-link, client_cert_header, redirect_rules, trust_config
- `addons/gcp/okta-conditional-access/README.md` — usage docs

**Modify:**
- `gcp/byo-project/variables.tf` — add optional `server_tls_policy` and `backend_custom_request_headers` variables
- `gcp/byo-project/loadbalancer.tf` — wire the new variables into `module.fleet_lb`

---

## Task 1: Create `variables.tf` for the addon

**Files:**
- Create: `addons/gcp/okta-conditional-access/variables.tf`

- [ ] **Step 1: Create the file**

```hcl
# addons/gcp/okta-conditional-access/variables.tf

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "customer_prefix" {
  description = "Prefix used for resource names"
  type        = string
  default     = "fleet"
}

variable "ca_certificate_pem_file" {
  description = "Path to the Fleet SCEP CA certificate in PEM format. Obtain with: curl 'https://<fleet-domain>/api/fleet/conditional_access/scep?operation=GetCACert' --output cacert.tmp && openssl x509 -inform der -in cacert.tmp -out ca.pem && rm cacert.tmp"
  type        = string
}

variable "subdomain_prefix" {
  description = "Subdomain prefix for the mTLS endpoint (e.g. 'okta' produces okta.<fleet_domain>)"
  type        = string
  default     = "okta"
}

variable "fleet_domain" {
  description = "The base Fleet domain, e.g. 'fleet.campusgroup.co'. Used to construct the mTLS redirect target."
  type        = string
}
```

---

## Task 2: Create `main.tf` for the addon

**Files:**
- Create: `addons/gcp/okta-conditional-access/main.tf`

- [ ] **Step 1: Create the file**

```hcl
# addons/gcp/okta-conditional-access/main.tf

data "google_project" "project" {
  project_id = var.project_id
}

resource "google_certificate_manager_trust_config" "this" {
  project     = var.project_id
  name        = "${var.customer_prefix}-okta-trust-config"
  description = "Fleet SCEP CA trust config for Okta conditional access mTLS"
  location    = "global"

  trust_stores {
    trust_anchors {
      pem_certificate = file(var.ca_certificate_pem_file)
    }
  }
}

resource "google_network_security_server_tls_policy" "this" {
  project     = var.project_id
  name        = "${var.customer_prefix}-okta-mtls-policy"
  description = "mTLS policy for Fleet Okta conditional access — rejects connections without a valid client cert"
  location    = "global"

  mtls_policy {
    client_validation_mode        = "REJECT_INVALID"
    client_validation_trust_config = "projects/${data.google_project.project.number}/locations/global/trustConfigs/${google_certificate_manager_trust_config.this.name}"
  }
}
```

---

## Task 3: Create `outputs.tf` for the addon

**Files:**
- Create: `addons/gcp/okta-conditional-access/outputs.tf`

- [ ] **Step 1: Create the file**

```hcl
# addons/gcp/okta-conditional-access/outputs.tf

output "server_tls_policy" {
  description = "Self-link of the ServerTLSPolicy. Pass to the fleet_lb module as server_tls_policy."
  value       = google_network_security_server_tls_policy.this.id
}

output "client_cert_header" {
  description = "Custom request header string that forwards the client certificate serial number to Fleet. Add to backends.default.custom_request_headers in the fleet_lb module."
  value       = "X-Client-Cert-Serial: {client_cert_serial_number}"
}

output "redirect_rules" {
  description = "Path matcher rules to add to the Fleet LB URL map, redirecting the Okta SSO path to the mTLS subdomain. Same shape as the AWS addon's redirect_rules output."
  value = [{
    paths = ["/api/fleet/conditional_access/idp/sso"]
    url_redirect = {
      https_redirect = true
      host_redirect  = "${var.subdomain_prefix}.${var.fleet_domain}"
      path_redirect  = "/api/fleet/conditional_access/idp/sso"
      strip_query    = false
    }
  }]
}

output "trust_config" {
  description = "The google_certificate_manager_trust_config resource."
  value       = google_certificate_manager_trust_config.this
}
```

---

## Task 4: Add `versions.tf` for the addon

**Files:**
- Create: `addons/gcp/okta-conditional-access/versions.tf`

- [ ] **Step 1: Create the file**

```hcl
# addons/gcp/okta-conditional-access/versions.tf

terraform {
  required_version = "~> 1.11"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.35.0"
    }
  }
}
```

---

## Task 5: Update `gcp/byo-project/variables.tf` to accept mTLS inputs

**Files:**
- Modify: `gcp/byo-project/variables.tf`

These two new variables allow the caller to pass addon outputs into the byo-project module, which forwards them to the LB module. Both are optional so existing deployments without the addon are unaffected.

- [ ] **Step 1: Append the two new variables to the end of the file**

```hcl
variable "server_tls_policy" {
  description = "Self-link of a ServerTLSPolicy to attach to the Fleet HTTPS proxy for mTLS. Set to the okta-conditional-access addon's server_tls_policy output to enable Okta conditional access."
  type        = string
  default     = null
}

variable "backend_custom_request_headers" {
  description = "Custom request headers to add to the default Fleet backend service. Used to forward client cert info (e.g. X-Client-Cert-Serial) when mTLS is enabled."
  type        = list(string)
  default     = []
}
```

---

## Task 6: Update `gcp/byo-project/loadbalancer.tf` to wire mTLS inputs

**Files:**
- Modify: `gcp/byo-project/loadbalancer.tf`

The `GoogleCloudPlatform/lb-http/google//modules/serverless_negs` module accepts `server_tls_policy` at the top level and `custom_request_headers` per-backend. We wire both in using the new variables.

- [ ] **Step 1: Update `module.fleet_lb` in `loadbalancer.tf`**

Replace the entire `module "fleet_lb"` block with:

```hcl
module "fleet_lb" {
  source  = "GoogleCloudPlatform/lb-http/google//modules/serverless_negs"
  version = "~> 12.0"

  project = var.project_id
  name    = "${var.prefix}-lb"

  ssl                             = true
  https_redirect                  = true
  managed_ssl_certificate_domains = [local.managed_ssl_domain]
  server_tls_policy               = var.server_tls_policy

  backends = {
    default = {
      description            = "Backend for Fleet Cloud Run service"
      enable_cdn             = false
      protocol               = "HTTP"
      custom_request_headers = var.backend_custom_request_headers
      groups = [
        {
          group = google_compute_region_network_endpoint_group.neg.id
        }
      ]

      log_config = {
        enable      = true
        sample_rate = 1.0
      }

      iap_config = {
        enable = false
      }
    }
  }

  depends_on = [google_compute_region_network_endpoint_group.neg]
}
```

---

## Task 7: Write the README

**Files:**
- Create: `addons/gcp/okta-conditional-access/README.md`

- [ ] **Step 1: Create the README**

````markdown
# GCP Okta Conditional Access

Enables Fleet's [Okta conditional access](https://fleetdm.com/guides/okta-conditional-access-integration) on GCP by attaching an mTLS `ServerTLSPolicy` to the existing Application Load Balancer. When a device authenticates through Okta, the LB validates its certificate against the Fleet SCEP CA and forwards the serial number to Fleet via the `X-Client-Cert-Serial` header.

GCP's Application Load Balancer supports mTLS natively — no separate load balancer is needed (contrast with the AWS addon).

## Requirements

- Fleet deployment using `gcp/byo-project` (or equivalent with `GoogleCloudPlatform/lb-http/google//modules/serverless_negs`)
- A valid Fleet instance reachable to obtain the CA certificate
- The CA certificate in PEM format stored at `resources/conditional-ca.pem` in your Terraform directory

## Differences from AWS Addon

| Concern | AWS | GCP |
| --- | --- | --- |
| CA cert storage | S3 bucket | Inline in `TrustConfig` (no object storage) |
| mTLS termination | Separate ALB | Existing LB via `ServerTLSPolicy` |
| Cert revocation | Supported | **Not supported** by GCP LB — see note below |
| Serial header | ALB-native header | Custom request header `{client_cert_serial_number}` |
| Extra infrastructure cost | Second ALB + global IP | None |

> **Revocation note:** GCP Application Load Balancers do not perform certificate revocation checking. Revoked certs with otherwise-valid chains will pass mTLS validation at the LB. Fleet itself checks the serial against its device records, so devices with revoked certs will still be blocked by Fleet — but the LB will not drop the connection at the TLS handshake.

## Obtaining the CA Certificate

Run these commands from your Terraform directory:

```sh
mkdir -p resources
curl 'https://<your-fleet-domain>/api/fleet/conditional_access/scep?operation=GetCACert' --output cacert.tmp
openssl x509 -inform der -in cacert.tmp -out resources/conditional-ca.pem
rm cacert.tmp
```

## Usage

```hcl
module "okta_conditional_access" {
  source = "github.com/fleetdm/fleet-terraform//addons/gcp/okta-conditional-access?depth=1&ref=tf-mod-addon-gcp-okta-conditional-access-v0.1.0"

  project_id              = var.project_id
  ca_certificate_pem_file = "${path.module}/resources/conditional-ca.pem"
  fleet_domain            = "fleet.example.com"
}

module "fleet" {
  source = "github.com/fleetdm/fleet-terraform//gcp/byo-project?depth=1&ref=..."

  # ... your existing fleet config ...

  # Wire in the mTLS policy and cert-serial header forwarding:
  server_tls_policy              = module.okta_conditional_access.server_tls_policy
  backend_custom_request_headers = [module.okta_conditional_access.client_cert_header]
}
```

You must also add the redirect rule to your URL map so that Okta's SSO redirect goes through the mTLS path. How you do this depends on whether you manage the URL map directly or through the LB module — add a path rule for `/api/fleet/conditional_access/idp/sso` that redirects to `okta.<fleet_domain>/api/fleet/conditional_access/idp/sso` with HTTPS.

The `redirect_rules` output provides the rule in a structured format:

```hcl
module.okta_conditional_access.redirect_rules
# => [{ paths = [...], url_redirect = { host_redirect = "okta.fleet.example.com", ... } }]
```

## Requirements

| Name | Version |
| --- | --- |
| terraform | ~> 1.11 |
| google | >= 6.35.0 |

## Inputs

| Name | Description | Type | Default | Required |
| --- | --- | --- | --- | --- |
| `project_id` | GCP project ID | `string` | — | yes |
| `customer_prefix` | Resource name prefix | `string` | `"fleet"` | no |
| `ca_certificate_pem_file` | Path to Fleet SCEP CA cert (PEM) | `string` | — | yes |
| `subdomain_prefix` | Subdomain prefix for the mTLS endpoint | `string` | `"okta"` | no |
| `fleet_domain` | Base Fleet domain e.g. `fleet.example.com` | `string` | — | yes |

## Outputs

| Name | Description |
| --- | --- |
| `server_tls_policy` | Self-link of the ServerTLSPolicy — pass to `server_tls_policy` on the fleet LB module |
| `client_cert_header` | Custom request header string — add to `backend_custom_request_headers` |
| `redirect_rules` | URL map path rules for the Okta SSO redirect |
| `trust_config` | The `google_certificate_manager_trust_config` resource |
````

---

## Task 8: Validate with `terraform validate`

**Files:** No changes

- [ ] **Step 1: Initialize the addon module**

```bash
cd addons/gcp/okta-conditional-access
terraform init
```

Expected: `Terraform has been successfully initialized!`

- [ ] **Step 2: Validate the addon module**

```bash
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Validate byo-project still passes**

```bash
cd ../../../gcp/byo-project
terraform validate
```

Expected: `Success! The configuration is valid.`

---

## Self-Review Checklist

**Spec coverage:**
- [x] `google_certificate_manager_trust_config` with inline PEM — Task 2
- [x] `google_network_security_server_tls_policy` with `REJECT_INVALID` — Task 2
- [x] No resource takeover; outputs wired via caller — Tasks 3, 5, 6
- [x] `X-Client-Cert-Serial` header forwarding — Task 3 (`client_cert_header` output)
- [x] Redirect rules output same shape as AWS addon — Task 3
- [x] `byo-project` updated with new optional vars — Tasks 5, 6
- [x] README with revocation note and usage example — Task 7
- [x] `versions.tf` — Task 4

**No placeholders found.**

**Type consistency:** `server_tls_policy` is `string` (self-link/id) in outputs.tf Task 3, accepted as `string` in variables.tf Task 5, passed directly to the LB module in Task 6. `backend_custom_request_headers` is `list(string)` throughout. Consistent.

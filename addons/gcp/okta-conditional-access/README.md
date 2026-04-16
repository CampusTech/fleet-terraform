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
| CA cert storage | S3 bucket | Inline in `TrustConfig` (no object storage needed) |
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

You must also add the redirect rule to your URL map so that Okta's SSO redirect goes through the mTLS path. Add a path rule for `/api/fleet/conditional_access/idp/sso` that redirects to `okta.<fleet_domain>/api/fleet/conditional_access/idp/sso` with HTTPS. The `redirect_rules` output provides this in a structured format:

```hcl
module.okta_conditional_access.redirect_rules
# => [{ paths = [...], url_redirect = { host_redirect = "okta.fleet.example.com", ... } }]
```

## First-time Deployment Notes

When applying this addon to an existing Fleet deployment for the first time, Terraform must replace the managed SSL certificate (to add the Okta subdomain). The existing certificate cannot be deleted while it is attached to the HTTPS proxy, which causes a 409 conflict. Work around this with the following steps before running `terraform apply`:

```sh
# 1. Create a temporary cert covering both domains
gcloud compute ssl-certificates create fleet-lb-cert-new \
  --domains=<fleet-domain>,okta.<fleet-domain> \
  --project=<project-id> \
  --global

# 2. Detach the old cert by swapping the proxy to the temp cert
gcloud compute target-https-proxies update fleet-lb-https-proxy \
  --ssl-certificates=fleet-lb-cert-new \
  --project=<project-id> \
  --global

# 3. Delete the old cert (now detached)
gcloud compute ssl-certificates delete fleet-lb-cert \
  --project=<project-id> --global --quiet

# 4. Apply — Terraform recreates fleet-lb-cert with both domains
terraform apply

# 5. Clean up the temporary cert
gcloud compute ssl-certificates delete fleet-lb-cert-new \
  --project=<project-id> --global --quiet
```

This is a one-time migration step. Future `terraform apply` runs will not require it.

Additionally, if a previous `terraform apply` partially failed and left the old module-managed URL map (`fleet-lb-url-map`) stuck in state, remove it before applying:

```sh
terraform state rm 'module.fleet.module.fleet_lb.google_compute_url_map.default[0]'
```

This is safe — the new `google_compute_url_map.fleet` resource (outside the module) takes over URL map ownership.

## Provider Requirements

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
| `trust_config_id` | The fully-qualified resource ID of the `google_certificate_manager_trust_config` |

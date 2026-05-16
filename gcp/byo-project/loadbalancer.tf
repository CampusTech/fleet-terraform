locals {
  # Clean the DNS record name for use in managed SSL cert domains (remove trailing dot)
  managed_ssl_domain = trim(var.dns_record_name, ".")

  # Construct backend service self_links directly to avoid a circular dependency.
  # The lb-http module names backend services "${name}-backend-${key}".
  fleet_backend_self_link      = "https://www.googleapis.com/compute/v1/projects/${var.project_id}/global/backendServices/${var.prefix}-lb-backend-default"
  fleet_bulk_backend_self_link = "https://www.googleapis.com/compute/v1/projects/${var.project_id}/global/backendServices/${var.prefix}-lb-backend-bulk"

  fleet_bulk_paths = [
    "/api/fleet/orbit/software_install/package",
    "/api/latest/fleet/software/package",
    # Classic global external URL maps only support terminal wildcards in
    # pathRules. Use this narrowest compatible match for package token downloads.
    "/api/latest/fleet/software/titles/*",
    "/api/v1/fleet/software/package",
    "/api/v1/fleet/software/titles/*",
    "/api/latest/fleet/mdm/apple/installers",
    "/api/latest/fleet/mdm/apple/installers/*",
    "/api/v1/fleet/mdm/apple/installers",
    "/api/v1/fleet/mdm/apple/installers/*",
  ]
}

# Create/Manage the DNS Zone in Cloud DNS
resource "google_dns_managed_zone" "fleet_dns_zone" {
  project  = var.project_id
  name     = "${var.prefix}-zone"
  dns_name = var.dns_zone_name
}

# URL map — managed directly so we can inject the Okta SSO redirect path rule
# and route large software installer transfers to the h2c backend.
resource "google_compute_url_map" "fleet" {
  project         = var.project_id
  name            = "${var.prefix}-lb"
  default_service = local.fleet_backend_self_link

  lifecycle {
    create_before_destroy = true
  }

  # Default host rule — sends all traffic to the Fleet backend
  host_rule {
    hosts        = ["*"]
    path_matcher = "default"
  }

  path_matcher {
    name            = "default"
    default_service = local.fleet_backend_self_link

    path_rule {
      paths   = local.fleet_bulk_paths
      service = local.fleet_bulk_backend_self_link
    }
  }

  # Okta subdomain host rule — redirects SSO path, forwards everything else
  dynamic "host_rule" {
    for_each = var.okta_subdomain != null ? [1] : []
    content {
      hosts        = [var.okta_subdomain]
      path_matcher = "okta"
    }
  }

  dynamic "path_matcher" {
    for_each = var.okta_subdomain != null ? [1] : []
    content {
      name            = "okta"
      default_service = local.fleet_backend_self_link

      path_rule {
        paths   = local.fleet_bulk_paths
        service = local.fleet_bulk_backend_self_link
      }

      path_rule {
        paths = ["/api/fleet/conditional_access/idp/sso"]
        url_redirect {
          https_redirect = true
          host_redirect  = var.okta_subdomain
          path_redirect  = "/api/fleet/conditional_access/idp/sso"
          strip_query    = false
        }
      }
    }
  }

  test {
    description = "software titles metadata stays on the primary backend"
    host        = local.managed_ssl_domain
    path        = "/api/latest/fleet/software/titles"
    service     = local.fleet_backend_self_link
  }

  test {
    description = "software package uploads use the h2c backend"
    host        = local.managed_ssl_domain
    path        = "/api/latest/fleet/software/package"
    service     = local.fleet_bulk_backend_self_link
  }

  test {
    description = "software package token downloads use the h2c backend"
    host        = local.managed_ssl_domain
    path        = "/api/latest/fleet/software/titles/1469/package/token/68d9ba68-1fad-44b2-8d73-6d7bfda9ac27"
    service     = local.fleet_bulk_backend_self_link
  }
}

# Configure the External HTTP(S) Load Balancer
module "fleet_lb" {
  source  = "GoogleCloudPlatform/lb-http/google//modules/serverless_negs"
  version = "~> 12.0"

  project = var.project_id
  name    = "${var.prefix}-lb"

  ssl                             = true
  https_redirect                  = true
  managed_ssl_certificate_domains = [local.managed_ssl_domain]

  # Use our custom URL map so we can inject Okta redirect rules and h2c path routing.
  create_url_map = false
  url_map        = google_compute_url_map.fleet.self_link

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

    bulk = {
      description            = "h2c backend for large Fleet software installer transfers"
      enable_cdn             = false
      protocol               = "HTTP"
      custom_request_headers = var.backend_custom_request_headers
      groups = [
        {
          group = google_compute_region_network_endpoint_group.bulk_neg.id
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

  depends_on = [
    google_compute_region_network_endpoint_group.neg,
    google_compute_region_network_endpoint_group.bulk_neg,
  ]
}

# Create the DNS A Record for the main Fleet domain
resource "google_dns_record_set" "fleet_dns_record" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.fleet_dns_zone.name
  name         = var.dns_record_name
  type         = "A"
  ttl          = 300

  rrdatas = [module.fleet_lb.external_ip]

  depends_on = [module.fleet_lb]
}

# ---------------------------------------------------------------------------
# Okta mTLS subdomain — separate proxy, IP, cert, and forwarding rule so
# that the mTLS ServerTLSPolicy only applies to okta.* traffic, not the
# main Fleet UI. GCP attaches TLS policies at the proxy level, so a
# dedicated proxy is required.
# ---------------------------------------------------------------------------

# Dedicated global IP for the Okta mTLS subdomain
resource "google_compute_global_address" "okta" {
  count   = var.okta_subdomain != null ? 1 : 0
  project = var.project_id
  name    = "${var.prefix}-okta-ip"
}

# Managed SSL cert for the Okta subdomain only
resource "google_compute_managed_ssl_certificate" "okta" {
  count   = var.okta_subdomain != null ? 1 : 0
  project = var.project_id
  name    = "${var.prefix}-okta-cert"

  managed {
    domains = [var.okta_subdomain]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# HTTPS proxy with mTLS policy — only used for okta.* traffic
resource "google_compute_target_https_proxy" "okta" {
  count   = var.okta_subdomain != null ? 1 : 0
  project = var.project_id
  name    = "${var.prefix}-okta-https-proxy"

  url_map           = google_compute_url_map.fleet.self_link
  ssl_certificates  = [google_compute_managed_ssl_certificate.okta[0].self_link]
  server_tls_policy = var.server_tls_policy
}

# Forwarding rule: okta IP:443 → okta HTTPS proxy
resource "google_compute_global_forwarding_rule" "okta_https" {
  count   = var.okta_subdomain != null ? 1 : 0
  project = var.project_id
  name    = "${var.prefix}-okta-https"

  ip_address = google_compute_global_address.okta[0].address
  port_range = "443"
  target     = google_compute_target_https_proxy.okta[0].self_link

  depends_on = [google_compute_target_https_proxy.okta]
}

# DNS A record for the Okta mTLS subdomain — points to the dedicated okta IP
resource "google_dns_record_set" "okta_dns_record" {
  count = var.okta_subdomain != null ? 1 : 0

  project      = var.project_id
  managed_zone = google_dns_managed_zone.fleet_dns_zone.name
  name         = "${var.okta_subdomain}."
  type         = "A"
  ttl          = 300

  rrdatas = [google_compute_global_address.okta[0].address]

  depends_on = [google_compute_global_address.okta]
}

# No-cloud check that newly created projects enable the baseline APIs the
# Fleet stack needs, including Certificate Manager for the regional load
# balancer certificates. Existing projects (create_project = false) are not
# touched: API enablement there remains the operator's responsibility.
#
# Every provider is mocked and module.fleet is overridden, so these runs never
# contact Google Cloud. The project factory itself is planned (not
# overridden) so its enabled_apis output reflects activate_apis. Run from the
# gcp/ directory:
#
#   terraform init -backend=false
#   terraform test

mock_provider "google" {
  mock_data "google_compute_zones" {
    defaults = {
      names = ["us-central1-a", "us-central1-b"]
    }
  }
}

mock_provider "google-beta" {
  mock_data "google_compute_zones" {
    defaults = {
      names = ["us-central1-a", "us-central1-b"]
    }
  }
}
mock_provider "random" {}
mock_provider "null" {}
mock_provider "time" {}
mock_provider "terracurl" {}

override_module {
  target  = module.fleet
  outputs = { fleet_service_account_email = "fleet-run-sa@fleet-test.iam.gserviceaccount.com" }
}

// Fork-only root additions: Okta mTLS addon (reads an untracked CA PEM) and
// the GeoLite2 image build (docker provider) are stubbed out.
mock_provider "docker" {}
mock_provider "local" {}

override_module {
  target = module.okta_conditional_access
  outputs = {
    server_tls_policy  = "projects/fleet-test/locations/global/serverTlsPolicies/fleet-mtls"
    client_cert_header = "X-Client-Cert-Serial: {client_cert_serial_number}"
  }
}

override_module {
  target = module.geolite2
  outputs = {
    image_digest                = "us-central1-docker.pkg.dev/fleet-test/fleet/fleet-geolite2@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    extra_environment_variables = {}
  }
}

variables {
  dns_zone_name   = "example.com."
  dns_record_name = "fleet.example.com."
}

run "new_project_enables_certificate_manager" {
  command = plan

  variables {
    org_id             = "123456789012"
    billing_account_id = "AAAAAA-BBBBBB-CCCCCC"
  }

  assert {
    condition     = contains(module.project_factory[0].enabled_apis, "certificatemanager.googleapis.com")
    error_message = "New projects must enable certificatemanager.googleapis.com for regional load balancer certificates."
  }

  assert {
    condition     = contains(module.project_factory[0].enabled_apis, "compute.googleapis.com")
    error_message = "New projects must keep enabling the existing baseline APIs."
  }
}

run "existing_project_does_not_manage_apis" {
  command = plan

  variables {
    create_project = false
    project_id     = "my-existing-project"
  }

  assert {
    condition     = length(module.project_factory) == 0
    error_message = "create_project=false must not create a project or manage its APIs."
  }
}

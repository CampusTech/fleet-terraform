terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = ">= 3.0.2"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0.0"
    }
  }
}

# Write the license key to a BuildKit secret file instead of a build ARG. ARG
# values are baked into image history (docker history), exposing the key to
# anyone with registry read. This file lives under the root module's .terraform
# dir (gitignored, 0600, outside the build context) and is mounted into the
# build as a secret.
resource "local_sensitive_file" "license_key" {
  content         = var.license_key
  filename        = "${path.root}/.terraform/geolite2-license-key"
  file_permission = "0600"
}

# Build the new image
resource "docker_image" "maxmind_fleet" {
  name = var.destination_image

  build {
    context  = path.module
    platform = "linux/amd64"
    build_args = {
      FLEET_IMAGE = var.fleet_image
    }
    # Mounted at /run/secrets/license_key during the download RUN only; requires
    # a buildx/BuildKit builder (Docker Desktop default).
    secrets {
      id  = "license_key"
      src = local_sensitive_file.license_key.filename
    }
    pull_parent = true
  }

  depends_on = [local_sensitive_file.license_key]
}

# push it to the specified repo
resource "docker_registry_image" "maxmind_fleet" {
  triggers = {
    fleet_digest = docker_image.maxmind_fleet.repo_digest
  }
  name          = docker_image.maxmind_fleet.name
  keep_remotely = true
}

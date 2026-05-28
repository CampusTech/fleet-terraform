output "extra_environment_variables" {
  value = {
    FLEET_GEOIP_DATABASE_PATH = "/opt/GeoLite2/GeoLite2-City.mmdb"
  }
}

output "image_digest" {
  description = "Image reference pinned to the pushed manifest digest (image@sha256:...). Use this as the Cloud Run / ECS / k8s image to guarantee callers pull exactly the build that completed, avoiding tag-push race conditions where the registry has the digest but not the tag."
  value       = "${docker_image.maxmind_fleet.name}@${docker_registry_image.maxmind_fleet.sha256_digest}"
}

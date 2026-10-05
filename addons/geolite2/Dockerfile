# syntax=docker/dockerfile:1.4
ARG FLEET_IMAGE

FROM ${FLEET_IMAGE}

USER root

# SECURITY: the MaxMind license key is a BuildKit secret, mounted only for this
# RUN. It never becomes an ARG/ENV and never lands in the image layers, history,
# or build context. wget runs -q so the key-bearing URL is not echoed to logs.
RUN --mount=type=secret,id=license_key \
    LK="$(cat /run/secrets/license_key)" && \
    mkdir -p /opt/GeoLite2 && cd /tmp && \
    wget "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&license_key=${LK}&suffix=tar.gz" -q -O GeoLite2-City.tar.gz && \
    wget "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&license_key=${LK}&suffix=tar.gz.sha256" -q -O GeoLite2-City.tar.gz.sha256 && \
    [ "$(awk '{ print $1 }' GeoLite2-City.tar.gz.sha256)" = "$(sha256sum GeoLite2-City.tar.gz | awk '{ print $1 }')" ] && \
    tar -xzf GeoLite2-City.tar.gz -C /opt/GeoLite2 --strip-components 1 && \
    rm -f GeoLite2-City.tar.gz*

USER fleet
# Might not be needed again, but keep it just in case
CMD ["fleet", "serve"]

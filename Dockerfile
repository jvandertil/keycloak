FROM quay.io/keycloak/keycloak:26.8.0-0 AS builder

ENV KC_HEALTH_ENABLED=true \
    KC_METRICS_ENABLED=true \
    KC_DB=postgres \
    KC_HTTPS_CLIENT_AUTH=required

# Add provider JARs here, before build. Normalize their timestamps if added.
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.8.0-0

USER 0
COPY --from=builder /opt/keycloak/ /opt/keycloak/
COPY --chmod=0555 docker-entrypoint.sh /opt/keycloak/bin/docker-entrypoint.sh

# Application files are readable by any numeric identity. Only data is
# writable by the default identity; custom identities supply their own mount.
RUN chmod -R a+rX,a-w /opt/keycloak \
    && chown -R 1000:1000 /opt/keycloak/data \
    && chmod -R u+rwX,go-rwx /opt/keycloak/data

ARG UPSTREAM_DIGEST=unknown
ARG UPSTREAM_VERSION=unknown
ARG SOURCE_REPOSITORY=https://github.com/jvandertil/keycloak
ARG SOURCE_REVISION=unknown
LABEL org.opencontainers.image.source="${SOURCE_REPOSITORY}" \
      org.opencontainers.image.revision="${SOURCE_REVISION}" \
      org.opencontainers.image.version="${UPSTREAM_VERSION}" \
      org.opencontainers.image.base.name="quay.io/keycloak/keycloak:${UPSTREAM_VERSION}" \
      org.opencontainers.image.base.digest="${UPSTREAM_DIGEST}"

ENV KC_DB=postgres \
    KC_HTTP_ENABLED=false \
    KC_HTTPS_PROTOCOLS=TLSv1.3

USER 1000:1000
EXPOSE 8443 9000
ENTRYPOINT ["/opt/keycloak/bin/docker-entrypoint.sh"]
CMD ["start", "--optimized"]

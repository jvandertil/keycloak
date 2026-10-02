# Keycloak image

This repository builds an optimized Keycloak image from the Quay release. 
PostgreSQL, health, metrics, and required HTTPS client authentication (mTLS) are fixed at build time for `start --optimized`. 
Database endpoints and credentials, TLS material, trust roots, hostname, and proxy settings are supplied at runtime. 
No providers or deployment files are included. The Docker context contains only the Dockerfile and entrypoint script.

## Build and test

From any directory, run `sh path/to/repository/build.sh` with Docker Buildx available. It resolves the upstream image digest and embeds it as `org.opencontainers.image.base.digest`, along with the exact upstream tag and source commit. For a full local check, run `bash tests/image.sh` on a Linux Docker host with `sudo`, `openssl`, and `curl`. The test builds the image, checks three numeric identities and writable paths, rejects root IDs, starts `start --optimized` with temporary PostgreSQL and TLS, waits for `/health/ready`, then sends SIGTERM.

The image defaults to numeric `1000:1000`. Set Docker's `--user UID:GID` or Compose's `user: "UID:GID"` to select another identity. No identity environment variables are needed. The entrypoint rejects UID or GID 0, then uses `exec` to start Keycloak. It never runs as root or changes ownership at startup.

The application tree is readable by arbitrary numeric identities. `/opt/keycloak/data` and `/tmp` must be writable by the selected identity. The built-in data directory is owned by `1000:1000`, so another identity needs a bind mount or pre-owned volume at `/opt/keycloak/data`. Use a private tmpfs for `/tmp`; no world-writable directory or privileged container is needed. A read-only root filesystem is supported with those two writable paths. Arbitrary IDs are supported subject to host filesystem and mounted-file permissions. Supplemental group access for private keys can be configured with `--group-add` or Compose `group_add` when needed.

## Run

Set runtime values in your deployment environment or secret manager. The example assumes `/srv/keycloak/data` belongs to UID/GID `10001:10001`, `/srv/keycloak/tls/tls.key` is readable by GID `10001`, and the certificate is readable by that user. Keep all of these paths outside this repository.

```sh
docker run --name keycloak --user 10001:10001 \
  --read-only --tmpfs /tmp:rw,nosuid,nodev,uid=10001,gid=10001,mode=0700 \
  -v /srv/keycloak/data:/opt/keycloak/data \
  -v /srv/keycloak/tls/tls.crt:/run/tls/tls.crt:ro \
  -v /srv/keycloak/tls/tls.key:/run/tls/tls.key:ro \
  -e KC_DB_URL='jdbc:postgresql://db.example:5432/keycloak' \
  -e KC_DB_USERNAME=keycloak -e KC_DB_PASSWORD \
  -e KC_HOSTNAME='https://login.example.com' \
  -e KC_HTTPS_CERTIFICATE_FILE=/run/tls/tls.crt \
  -e KC_HTTPS_CERTIFICATE_KEY_FILE=/run/tls/tls.key \
  -p 8443:8443 -m 2g keycloak:26.7.4-0 start --optimized
```

Supply `KC_DB_PASSWORD` from your deployment secret manager before running this example. The example database address is a placeholder. Keep client certificate authentication configured with appropriate runtime trust roots; mount those read-only too. Do not put TLS keys, database keys, passwords, or trust roots in this repository or build context.

For PEM private keys, use a host mode such as `0640`, with the file owned by the runtime UID or by a group in the container's supplemental groups. Parent directories must allow traversal. Bind mounts keep their host ownership; the image does not `chown` them. Use `:ro` for certificate, key, trust, and database-secret mounts. If the host uses SELinux, apply the host's appropriate volume labeling while preserving read-only access.

## Compose

Keep the Compose file in a deployment directory outside this repository. Set the numeric identity with `user:` and match the tmpfs ownership to it. This example uses `10001:10001`; prepare the data directory and mounted-file permissions for that identity as in the Docker example. Set `KC_DB_PASSWORD` with a secret mechanism appropriate for your deployment.

```yaml
services:
  keycloak:
    image: ghcr.io/jvandertil/keycloak@sha256:REPLACE_WITH_PUBLISHED_DIGEST
    user: "10001:10001"
    environment:
      KC_DB_URL: "${KC_DB_URL:?}"
      KC_DB_USERNAME: "${KC_DB_USERNAME:?}"
      KC_DB_PASSWORD: "${KC_DB_PASSWORD:?}"
      KC_HOSTNAME: "${KC_HOSTNAME:?}"
      KC_HTTPS_CERTIFICATE_FILE: /run/tls/tls.crt
      KC_HTTPS_CERTIFICATE_KEY_FILE: /run/tls/tls.key
    volumes:
      - ./runtime-data:/opt/keycloak/data
      - ./tls/tls.crt:/run/tls/tls.crt:ro
      - ./tls/tls.key:/run/tls/tls.key:ro
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,uid=10001,gid=10001,mode=0700
    ports:
      - "8443:8443"
    mem_limit: 2g
    command: ["start", "--optimized"]
```

Omit `user:` to use the default `1000:1000`, and adjust tmpfs ownership and mounted-file permissions accordingly. The entrypoint rejects UID/GID 0. Choose values that can read every mounted file and write the data volume and tmpfs. Do not expose port 9000 publicly. Health and metrics are on the management port; probe `/health/ready` from a trusted internal network. With HTTPS enabled, the management endpoint uses HTTPS unless configured separately. Expose 9000 only to your monitoring network if an external probe needs it.

Keycloak's default heap can use up to 70% of the container memory limit. Set a limit in production; 2 GiB is a reasonable small production starting point, then size it from observed workload and memory use. Proxy settings such as `KC_PROXY_HEADERS` and trusted proxy addresses belong in runtime configuration.

## Versioning, upstream tracking, and publication

Weekly Dependabot Docker checks can propose base-image changes. Dependabot handling of image tags with suffixes such as `26.7.4-0` is not guaranteed here, so a separate weekly workflow checks stable `keycloak/keycloak` GitHub releases, verifies a matching Quay tag, and opens a review PR changing both `FROM` lines. Review both lines and release notes. Upstream PRs are never auto-merged. 

The GHCR workflow runs on `main`, rebuilds and runs the image checks, then publishes `ghcr.io/jvandertil/keycloak:<exact-upstream-tag>-r<main-commit-count>` and `sha-<full-commit-sha>`. For example, `26.7.4-0-r3` uses `r3` for the repository's full-history commit count, **not** a Keycloak patch number. Docker tags cannot contain `+`. The workflow checks whether either tag exists and refuses to reuse it. Tags are convenient references; deploy by the published `sha256` image digest. OCI labels record the exact upstream version, upstream image digest, repository URL, and source commit. Avoid shallow Git history when deriving `rN`.

For an upgrade, review the upstream release and migration notes, update both `FROM` lines through a PR, run the image checks, deploy the new digest to a staging environment, back up PostgreSQL, and test login and readiness before promoting. Treat Keycloak database migrations as part of the deployment plan; keep a rollback strategy that accounts for schema changes.

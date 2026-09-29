#!/usr/bin/env bash
set -euo pipefail

# Name the active check so any unexpected command failure is identifiable.
# Keep cleanup in the same EXIT handler so failures retain their exit status.
check='Dockerfile base-stage pin'
work= network= server= db=
passed() { printf '[✓] %s passed\n' "$check"; }
finish() {
  status=$?
  trap - EXIT
  if (( status != 0 )); then
    printf '[X] %s failed (exit %s)\n' "$check" "$status" >&2
  fi
  if [[ -n "$server" && -n "$db" ]]; then
    docker rm -f "$server" "$db" >/dev/null 2>&1 || true
  fi
  if [[ -n "$network" ]]; then
    docker network rm "$network" >/dev/null 2>&1 || true
  fi
  if [[ -n "$work" ]]; then
    sudo rm -rf "$work" || true
  fi
  exit "$status"
}
trap finish EXIT

# Check the Dockerfile before building: both Keycloak stages must use the
# same explicit release tag, including an optional numeric suffix such as -0.
cd "$(dirname "$0")/.."
mapfile -t bases < <(sed -nE 's/^FROM quay.io\/keycloak\/keycloak:([^ ]+).*/\1/p' Dockerfile)
test "${#bases[@]}" -eq 2
test "${bases[0]}" = "${bases[1]}"
[[ "${bases[0]}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$ ]]
passed

# Resolve the upstream image digest, build the image, and confirm that the
# default process identity and recorded base digest match the intended inputs.
check='Image build'
image="keycloak-test:${bases[0]}"
digest=$(docker buildx imagetools inspect "quay.io/keycloak/keycloak:${bases[0]}" --format '{{.Manifest.Digest}}')
docker build --pull --build-arg "UPSTREAM_VERSION=${bases[0]}" \
  --build-arg "UPSTREAM_DIGEST=$digest" --build-arg "SOURCE_REVISION=$(git rev-parse HEAD)" \
  -t "$image" .
passed
check='Default image identity (1000:1000)'
test "$(docker image inspect "$image" --format '{{.Config.User}}')" = '1000:1000'
passed
check='Upstream digest metadata'
test "$(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.base.digest"}}')" = "$digest"
passed

# Keep all test data and containers isolated. The EXIT trap also cleans up
# when a check fails; sudo is needed for directories owned by test UIDs.
work=$(mktemp -d)
network="keycloak-test-$$"
server="keycloak-test-$$"
db="keycloak-db-$$"

# Exercise the default UID/GID and two different numeric pairs. Each pair
# gets a private data mount and tmpfs while the image filesystem is read-only.
# The first run goes through the entrypoint; the second checks application
# readability and actual writes to both required runtime paths.
for identity in 1000:1000 1001:1002 20001:30001; do
  check="UID/GID $identity startup and runtime path access"
  uid=${identity%:*}; gid=${identity#*:}
  mkdir "$work/data-$uid"
  chmod 700 "$work/data-$uid"
  sudo chown "$identity" "$work/data-$uid"
  docker run --rm --user "$identity" -e "PUID=$uid" -e "PGID=$gid" \
    --read-only --tmpfs "/tmp:rw,nosuid,nodev,uid=$uid,gid=$gid,mode=0700" \
    -v "$work/data-$uid:/opt/keycloak/data" "$image" --version >/dev/null
  docker run --rm --user "$identity" --entrypoint /bin/sh \
    --read-only --tmpfs "/tmp:rw,nosuid,nodev,uid=$uid,gid=$gid,mode=0700" \
    -v "$work/data-$uid:/opt/keycloak/data" "$image" -c \
    'test -r /opt/keycloak/lib/quarkus-run.jar && test -w /opt/keycloak/data && test -w /tmp && touch /opt/keycloak/data/probe /tmp/probe'
  passed
done

# Reject root in either half of the process identity, then reject invalid
# PUID/PGID declarations even when Docker itself selects a valid user.
for identity in 0:1000 1000:0; do
  check="Root identity rejection ($identity)"
  if docker run --rm --user "$identity" "$image" --help >/dev/null 2>&1; then
    result=0
  else
    result=$?
  fi
  if [[ "$result" != 64 ]]; then
    echo "Expected entrypoint exit 64, got $result" >&2; exit 1
  fi
  passed
done
for invalid in 'PUID=0' 'PGID=0' 'PUID=abc' 'PGID=-1'; do
  check="Invalid identity declaration rejection ($invalid)"
  if docker run --rm --user 1000:1000 -e "$invalid" "$image" --help >/dev/null 2>&1; then
    result=0
  else
    result=$?
  fi
  if [[ "$result" != 64 ]]; then
    echo "Expected entrypoint exit 64, got $result" >&2; exit 1
  fi
  passed
done

# Create temporary TLS material and start an isolated PostgreSQL instance.
# The private key is group-readable by the Keycloak process and later mounted
# read-only, as it would be in a real deployment.
check='PostgreSQL test setup and readiness'
openssl req -x509 -newkey rsa:2048 -noenc -days 1 -subj '/CN=localhost' \
  -keyout "$work/tls.key" -out "$work/tls.crt" >/dev/null 2>&1
chmod 644 "$work/tls.crt"
chmod 640 "$work/tls.key"
sudo chown "$(id -u):1000" "$work/tls.key"
docker network create "$network" >/dev/null
docker run -d --name "$db" --network "$network" \
  -e POSTGRES_USER=keycloak -e POSTGRES_PASSWORD=test-only -e POSTGRES_DB=keycloak \
  postgres:18-alpine >/dev/null
for _ in {1..30}; do
  if docker exec "$db" pg_isready -U keycloak >/dev/null 2>&1; then break; fi
  sleep 1
done
docker exec "$db" pg_isready -U keycloak >/dev/null
passed

# Start the production command against PostgreSQL with the same read-only
# filesystem layout used above. The main listener still uses HTTPS and its
# required client authentication. For this test only, serve management probes
# over HTTP; the host publishes port 9000 solely on loopback.
check='Keycloak start --optimized and /health/ready'
docker run -d --name "$server" --network "$network" --user 1000:1000 \
  --read-only --tmpfs /tmp:rw,nosuid,nodev,uid=1000,gid=1000,mode=0700 \
  -v "$work/data-1000:/opt/keycloak/data" \
  -v "$work/tls.crt:/run/tls/tls.crt:ro" -v "$work/tls.key:/run/tls/tls.key:ro" \
  -p 127.0.0.1::9000 \
  -e PUID=1000 -e PGID=1000 \
  -e KC_DB_URL="jdbc:postgresql://$db:5432/keycloak" \
  -e KC_DB_USERNAME=keycloak -e KC_DB_PASSWORD=test-only \
  -e KC_HOSTNAME=https://localhost:8443 \
  -e KC_HTTPS_CERTIFICATE_FILE=/run/tls/tls.crt \
  -e KC_HTTPS_CERTIFICATE_KEY_FILE=/run/tls/tls.key \
  -e KC_HTTP_MANAGEMENT_SCHEME=http \
  "$image" start --optimized >/dev/null

# Wait for /health/ready to report UP, rather than treating an open port or
# a running container as proof that Keycloak finished starting successfully.
port=$(docker port "$server" 9000/tcp | sed 's/.*://')
ready=0
for _ in {1..120}; do
  if curl -fsS "http://127.0.0.1:$port/health/ready" 2>/dev/null | grep -Eq '"status"[[:space:]]*:[[:space:]]*"UP"'; then
    ready=1; break
  fi
  if ! docker inspect -f '{{.State.Running}}' "$server" | grep -q true; then
    docker logs "$server"; exit 1
  fi
  sleep 2
done
if [[ "$ready" != 1 ]]; then docker logs "$server"; exit 1; fi
passed

# Docker sends SIGTERM to PID 1. A clean stop here checks that the entrypoint
# execs Keycloak and that Keycloak can complete its shutdown path.
check='SIGTERM graceful shutdown'
docker stop -t 30 "$server" >/dev/null
exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$server")
if [[ "$exit_code" != 143 && "$exit_code" != 0 ]]; then
  echo "Unexpected SIGTERM exit code: $exit_code" >&2; exit 1
fi
passed

#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$repo_dir"

upstream_tag=$(sed -n '1s|^FROM quay.io/keycloak/keycloak:\([^ ]*\).*|\1|p' Dockerfile)
test -n "$upstream_tag"
upstream_digest=$(docker buildx imagetools inspect "quay.io/keycloak/keycloak:$upstream_tag" --format '{{.Manifest.Digest}}')
test -n "$upstream_digest"
revision=$(git rev-parse HEAD)

docker build --pull \
    --build-arg "UPSTREAM_DIGEST=$upstream_digest" \
    --build-arg "UPSTREAM_VERSION=$upstream_tag" \
    --build-arg "SOURCE_REVISION=$revision" \
    -t "keycloak:$upstream_tag" "$repo_dir"

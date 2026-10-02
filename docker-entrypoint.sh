#!/bin/sh
set -e

# Docker's --user / Compose user selects the process identity.
uid= gid=
while read -r field real effective rest; do
    case "$field" in
        Uid:) uid=$effective ;;
        Gid:) gid=$effective ;;
    esac
    [ -n "$uid" ] && [ -n "$gid" ] && break
done < /proc/self/status

if [ -z "$uid" ] || [ -z "$gid" ] || [ "$uid" = 0 ] || [ "$gid" = 0 ]; then
    echo 'Container UID/GID must be nonzero; set Docker --user or Compose user' >&2
    exit 64
fi

exec /opt/keycloak/bin/kc.sh "$@"

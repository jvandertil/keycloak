#!/bin/sh
set -e

# PUID/PGID describe the identity selected by --user / Compose user.
for value in "${PUID:-}" "${PGID:-}"; do
    case "$value" in
        ''|[1-9]* ) ;;
        * ) echo 'PUID and PGID must be nonzero decimal IDs' >&2; exit 64 ;;
    esac
    case "$value" in
        *[!0-9]* ) echo 'PUID and PGID must be nonzero decimal IDs' >&2; exit 64 ;;
    esac
done

uid= gid=
while read -r field real effective rest; do
    case "$field" in
        Uid:) uid=$effective ;;
        Gid:) gid=$effective ;;
    esac
    [ -n "$uid" ] && [ -n "$gid" ] && break
done < /proc/self/status

if [ -z "$uid" ] || [ -z "$gid" ] || [ "$uid" = 0 ] || [ "$gid" = 0 ] || \
   { [ -n "${PUID:-}" ] && [ "$uid" != "$PUID" ]; } || \
   { [ -n "${PGID:-}" ] && [ "$gid" != "$PGID" ]; }; then
    echo 'Container UID/GID must be nonzero and match PUID/PGID when set' >&2
    exit 64
fi

exec /opt/keycloak/bin/kc.sh "$@"

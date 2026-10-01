#!/bin/sh
# Store outside web roots on encrypted storage; this dump contains credentials.
set -eu
umask 077
cd /opt/farmerplus-keycloak
mkdir -p backups
stamp=$(date -u +%Y%m%dT%H%M%SZ)
temporary="backups/keycloak-$stamp.dump.partial"
trap 'rm -f "$temporary"' EXIT HUP INT TERM
docker compose -f compose.yaml -f compose.agritec.yaml exec -T database pg_dump -U keycloak -d keycloak -Fc > "$temporary"
test -s "$temporary"
docker compose -f compose.yaml -f compose.agritec.yaml exec -T database pg_restore --list < "$temporary" >/dev/null
mv "$temporary" "backups/keycloak-$stamp.dump"
if docker compose -f compose.application.yaml ps --status running --services | grep -qx appdb; then
    temporary="backups/application-$stamp.dump.partial"
    docker compose -f compose.application.yaml exec -T appdb pg_dump -U farmerplus -d farmerplus -Fc > "$temporary"
    test -s "$temporary"
    docker compose -f compose.application.yaml exec -T appdb pg_restore --list < "$temporary" >/dev/null
    mv "$temporary" "backups/application-$stamp.dump"
fi
# Preserve encryption keys alongside database backups, in this root-only folder.
tar -czf "backups/configuration-$stamp.tar.gz" .env private compose*.yaml gateway.conf
# No automatic deletion: set retention after confirming off-host recovery policy.

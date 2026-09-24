#!/bin/bash
# Install the cumulative adminui patch (provider retire fix + force-password fix) and restart OpenMRS.
# Needed only if the .OpenMRS volume is recreated or the module is replaced.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${CONTAINER:-openmrs-app}"
TARGET=/usr/local/tomcat/.OpenMRS/modules/adminui-1.6.0.omod
EXPECTED_MD5=db7365645e8b9f70c62c1bc38b1822d2

echo "==> installing patched adminui-1.6.0.omod into $CONTAINER (.OpenMRS volume)"
docker cp "$DIR/adminui-1.6.0.omod" "$CONTAINER:$TARGET"
docker exec "$CONTAINER" chown root:1000 "$TARGET"
got=$(docker exec "$CONTAINER" md5sum "$TARGET" | cut -d' ' -f1)
[ "$got" = "$EXPECTED_MD5" ] || { echo "md5 mismatch: $got (expected $EXPECTED_MD5)"; exit 1; }
echo "    md5 $got OK"

echo "==> restarting $CONTAINER (expect ~2-3 min downtime)"
docker restart "$CONTAINER" >/dev/null

echo "==> waiting for OpenMRS to come up"
for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8080/openmrs/login.htm || true)
    [ "$code" = "200" ] && { echo "    up after ~$((i*5))s"; break; }
    sleep 5
done

exec "$DIR/verify.sh"

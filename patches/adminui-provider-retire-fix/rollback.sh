#!/bin/bash
# Roll back to the previous deployed adminui: the force-password fix only (provider retire bug returns).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${CONTAINER:-openmrs-app}"
PREV="$DIR/../adminui-forcepassword-fix/adminui-1.6.0.omod"

echo "==> reinstalling force-password-fix-only adminui-1.6.0.omod into $CONTAINER"
docker cp "$PREV" "$CONTAINER:/usr/local/tomcat/.OpenMRS/modules/adminui-1.6.0.omod"
docker exec "$CONTAINER" chown root:1000 /usr/local/tomcat/.OpenMRS/modules/adminui-1.6.0.omod
docker exec "$CONTAINER" md5sum /usr/local/tomcat/.OpenMRS/modules/adminui-1.6.0.omod

echo "==> restarting $CONTAINER (expect ~2-3 min downtime)"
docker restart "$CONTAINER" >/dev/null
for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8080/openmrs/login.htm || true)
    [ "$code" = "200" ] && { echo "    up after ~$((i*5))s"; break; }
    sleep 5
done

exec "$DIR/../adminui-forcepassword-fix/verify.sh"

#!/bin/bash
# Credential-free check that the provider retire/restore/save fix is being served.
# uiframework serves module resources without authentication, so an anonymous GET is enough.
# This proves deployment only; the functional check (retire a provider in the UI) is in README.md.
set -uo pipefail
BASE="${BASE:-http://localhost:8080/openmrs}"
URL="$BASE/ms/uiframework/resource/adminui/scripts/fragments/systemadmin/providerDetails.js"
body=$(mktemp); trap 'rm -f "$body"' EXIT

code=$(curl -s -o "$body" -w '%{http_code}' "$URL")
if [ "$code" != "200" ]; then
    echo "FAIL: $URL -> HTTP $code. Is OpenMRS up? (docker logs openmrs-app)"
    exit 1
fi
if grep -q 'headers: { "Content-Type": "application/x-www-form-urlencoded' "$body" \
   && grep -q 'if (value === undefined || value === null) return;' "$body"; then
    echo "PASS: patched providerDetails.js is served (Content-Type on the action, unset values skipped)."
else
    echo "FAIL: the unpatched providerDetails.js is served. Run apply.sh."
    exit 1
fi

# The force-password fix lives in the same omod; make sure it did not regress.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../adminui-forcepassword-fix/verify.sh"

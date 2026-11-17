#!/usr/bin/env bash
# Smoke test against a running workbench (make up). Reads .env for ports and the test password.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; [ -f .env ] && . ./.env; set +a
FRONTEND="http://localhost:${FRONTEND_PORT:-8080}"
KEYCLOAK="http://localhost:${KEYCLOAK_PORT:-8081}"
REALM="$KEYCLOAK/realms/interview-copilot"
fail=0
ok()   { printf 'PASS  %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fail=1; }
skip() { printf 'SKIP  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

token_for() {
  curl -s -X POST "$REALM/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=interview-copilot-spa -d scope="openid interview-copilot/user" \
    -d username="$1" --data-urlencode password="${TEST_USER_PASSWORD}" |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))'
}
sub_of() { python3 -c 'import base64,json,sys; p=sys.argv[1].split(".")[1]; p+="="*(-len(p)%4); print(json.loads(base64.urlsafe_b64decode(p))["sub"])' "$1"; }
exec_in() { docker compose exec -T "$1" bash -c "$2" >/dev/null 2>&1; }
reaches() { exec_in "$1" "timeout 3 bash -c 'exec 3<>/dev/tcp/$2/${3:-8080}'"; }

check "frontend loads" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $FRONTEND/)\" = 200 ]"
for s in backend internal-gateway bff edge-gateway; do
  check "$s is healthy" "[ \"\$(docker compose ps --format '{{.Health}}' $s)\" = healthy ]"
done

TOKEN=$(token_for journalist)
check "login works with the test user" "[ -n '$TOKEN' ]"
SUB=$(sub_of "$TOKEN")

check "unauthenticated call gets 401 at the edge" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $FRONTEND/api/whoami)\" = 401 ]"
check "authenticated call reaches the backend end to end" \
  "curl -s -H 'Authorization: Bearer $TOKEN' $FRONTEND/api/whoami | grep -q '\"userId\":\"$SUB\"'"
check "forged X-User-Id is ignored" \
  "curl -s -H 'Authorization: Bearer $TOKEN' -H 'X-User-Id: forged' $FRONTEND/api/whoami | grep -q '\"userId\":\"$SUB\"'"

skip "a user cannot read another user's session (needs sessions, milestone 6)"
skip "SSE stream stays open through both gateways (needs the suggestion stream, milestone 4)"

check "a transcript JSON can be written to the local S3 store" \
  "echo '{}' | docker compose exec -T -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_DEFAULT_REGION=us-east-1 s3 aws --endpoint-url http://localhost:4566 s3 cp - s3://transcripts/smoke.json >/dev/null"

check "BFF cannot reach the backend directly" "! reaches bff backend"
check "BFF reaches the internal gateway (control)" "reaches bff internal-gateway"
check "edge gateway cannot reach the internal gateway" "! reaches edge-gateway internal-gateway"
check "edge gateway cannot reach the backend" "! reaches edge-gateway backend"
check "internal gateway cannot reach Postgres" "! reaches internal-gateway postgres 5432"
check "frontend cannot reach the BFF" "! docker compose exec -T frontend sh -c 'wget -q -T 3 -O /dev/null http://bff:8080/actuator/health/readiness' 2>/dev/null"
check "edge gateway can reach the BFF (control)" "reaches edge-gateway bff"

exit $fail

#!/usr/bin/env bash
# Smoke test against a running workbench (make up). Reads .env for ports and the test password.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; [ -f .env ] && . ./.env; set +a
FRONTEND="http://localhost:${FRONTEND_PORT:-8080}"
MAILPIT="http://localhost:${MAILPIT_PORT:-8025}"
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

check "unauthenticated call gets 401 at the edge" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $FRONTEND/api/v1/whoami)\" = 401 ]"
check "authenticated call reaches the backend end to end" \
  "curl -s -H 'Authorization: Bearer $TOKEN' $FRONTEND/api/v1/whoami | grep -q '\"userId\":\"$SUB\"'"
check "forged X-User-Id is ignored" \
  "curl -s -H 'Authorization: Bearer $TOKEN' -H 'X-User-Id: forged' $FRONTEND/api/v1/whoami | grep -q '\"userId\":\"$SUB\"'"

if [ -z "${DEEPGRAM_API_KEY:-}" ] || [ "${DEEPGRAM_API_KEY}" = CHANGE_ME ]; then
  skip "stt-token never leaks the API key (no real DEEPGRAM_API_KEY set)"
else
  check "stt-token returns a short-lived token and never the API key" \
    "R=\$(curl -s -H 'Authorization: Bearer $TOKEN' '$FRONTEND/api/v1/stt-token?provider=deepgram'); echo \"\$R\" | grep -q '\"token\"' && ! echo \"\$R\" | grep -qF \"\${DEEPGRAM_API_KEY:-__none__}\""
fi

# --- accounts: sign-up and password reset (no token needed) ---
EMAIL="smoke-$RANDOM$RANDOM@example.test"; PW1="first-pass-$RANDOM$RANDOM"; PW2="second-pass-$RANDOM$RANDOM"
api_post() { curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$2" "$FRONTEND$1"; }
login_code() { curl -s -o /dev/null -w '%{http_code}' -X POST "$REALM/protocol/openid-connect/token" -d grant_type=password -d client_id=interview-copilot-spa --data-urlencode username="$1" --data-urlencode password="$2"; }
check "sign-up creates an account without a token" "[ \"\$(api_post /api/v1/accounts/sign-up '{\"email\":\"$EMAIL\",\"name\":\"Smoke\",\"password\":\"$PW1\"}')\" = 201 ]"
check "the new account can sign in" "[ \"\$(login_code $EMAIL $PW1)\" = 200 ]"
check "signing up the same email again gets 409" "[ \"\$(api_post /api/v1/accounts/sign-up '{\"email\":\"$EMAIL\",\"name\":\"Smoke\",\"password\":\"$PW1\"}')\" = 409 ]"
check "a too-short password is rejected with 400" "[ \"\$(api_post /api/v1/accounts/sign-up '{\"email\":\"x$EMAIL\",\"name\":\"Smoke\",\"password\":\"short\"}')\" = 400 ]"
check "reset request for an unknown email still gets 202" "[ \"\$(api_post /api/v1/accounts/password-reset/request '{\"email\":\"nobody-$EMAIL\"}')\" = 202 ]"
check "reset request for the account gets 202" "[ \"\$(api_post /api/v1/accounts/password-reset/request '{\"email\":\"$EMAIL\"}')\" = 202 ]"
RESET_TOKEN=""
for _ in $(seq 1 20); do
  MID=$(curl -s "$MAILPIT/api/v1/search?query=to:$EMAIL" | python3 -c 'import json,sys; m=json.load(sys.stdin).get("messages",[]); print(m[0]["ID"] if m else "")')
  [ -n "$MID" ] && break; sleep 1
done
[ -n "${MID:-}" ] && RESET_TOKEN=$(curl -s "$MAILPIT/api/v1/message/$MID" | python3 -c 'import json,re,sys; m=re.search(r"token=([A-Za-z0-9_-]+)", json.load(sys.stdin)["Text"]); print(m.group(1) if m else "")')
check "the reset email arrives with a link" "[ -n '$RESET_TOKEN' ]"
check "the link sets a new password" "[ \"\$(api_post /api/v1/accounts/password-reset/confirm '{\"token\":\"$RESET_TOKEN\",\"newPassword\":\"$PW2\"}')\" = 204 ]"
check "the old password no longer works and the new one does" "[ \"\$(login_code $EMAIL $PW1)\" != 200 ] && [ \"\$(login_code $EMAIL $PW2)\" = 200 ]"
check "the reset link works only once" "[ \"\$(api_post /api/v1/accounts/password-reset/confirm '{\"token\":\"$RESET_TOKEN\",\"newPassword\":\"$PW1\"}')\" = 400 ]"
check "an unknown API version is not routed" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer $TOKEN' $FRONTEND/api/v2/whoami)\" = 404 ]"

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

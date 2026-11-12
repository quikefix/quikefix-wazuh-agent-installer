#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

HOSTNAME="lc.quikefix.info"
PROD_API="qflm-api"
PG="qflm-postgres"
DB="qflm"
PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"
ADMIN_USER_FILE="/opt/qflm/secrets/auth/platform-admin-username"
ADMIN_PASS_FILE="/opt/qflm/secrets/auth/platform-admin-password"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="/opt/qflm/backups/recovery7e5-public-validation-$STAMP.txt"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p /opt/qflm/backups
exec > >(tee "$REPORT") 2>&1

printf '%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7E5"
printf '%s\n' " PUBLIC CLOUDFLARE PREVIEW VALIDATION"
printf '%s\n' "======================================================"

printf '\n=== 1. PRODUCTION SAFETY BASELINE ===\n'
IMG=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
RUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
LIC=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
INS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
printf 'image=%s running=%s migrations=%s licenses=%s installations=%s\n' "$IMG" "$RUN" "$MIG" "$LIC" "$INS"
[ "$IMG" = "qflm-api:recovery6f3-candidate" ] || die "unexpected production image"
[ "$RUN" = true ] || die "production API not running"
printf '%s\n' "production_baseline=PASS"

printf '\n=== 2. PREVIEW + TUNNEL STATUS ===\n'
[ "$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null)" = true ] || die "preview API not running"
[ "$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null)" = true ] || die "preview GUI not running"
pgrep -x cloudflared >/dev/null 2>&1 || die "cloudflared process not running"
printf '%s\n' "preview_stack=PASS"
printf '%s\n' "cloudflared_process=PASS"

printf '\n=== 3. PUBLIC ROUTE TEST ===\n'
LOGIN_HTTP=$(curl --max-time 20 -sS -o /dev/null -w '%{http_code}' "https://$HOSTNAME/login" || true)
INSTALL_HTTP=$(curl --max-time 20 -sS -o /dev/null -w '%{http_code}' "https://$HOSTNAME/installations" || true)
printf 'login_http=%s installations_http=%s\n' "$LOGIN_HTTP" "$INSTALL_HTTP"
[ "$LOGIN_HTTP" = 200 ] || die "public login route not HTTP 200"
[ "$INSTALL_HTTP" = 200 ] || die "public installations route not HTTP 200"
printf '%s\n' "public_routes=PASS"

printf '\n=== 4. PUBLIC AUTHENTICATION TEST ===\n'
[ -s "$ADMIN_USER_FILE" ] || die "platform admin username file missing"
[ -s "$ADMIN_PASS_FILE" ] || die "platform admin password file missing"
ADMIN_USER="$(cat "$ADMIN_USER_FILE")"
ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"
LOGIN_JSON=$(python3 - "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)
LOGIN_RESPONSE=$(printf '%s' "$LOGIN_JSON" | curl --max-time 20 -fsS -H 'Content-Type: application/json' -X POST "https://$HOSTNAME/api/v1/auth/login" --data-binary @-) || die "public admin login failed"
TOKEN=$(python3 - "$LOGIN_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["accessToken"])
PY
)
REFRESH=$(python3 - "$LOGIN_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["refreshToken"])
PY
)
[ -n "$TOKEN" ] || die "public access token missing"
printf 'admin_username=%s\n' "$ADMIN_USER"
printf '%s\n' "public_admin_login=PASS"

printf '\n=== 5. PUBLIC /ME + INSTALLATION API TEST ===\n'
ME_JSON=$(curl --max-time 20 -fsS -H "Authorization: Bearer $TOKEN" "https://$HOSTNAME/api/v1/auth/me") || die "public /me failed"
ME_USER=$(python3 - "$ME_JSON" <<'PY'
import json,sys
print(json.loads(sys.argv[1]).get("username",""))
PY
)
[ "$ME_USER" = "$ADMIN_USER" ] || die "public /me username mismatch"
INSTALL_JSON=$(curl --max-time 20 -fsS -H "Authorization: Bearer $TOKEN" "https://$HOSTNAME/api/v1/admin/installations") || die "public installations API failed"
INSTALL_COUNT=$(python3 - "$INSTALL_JSON" <<'PY'
import json,sys
print(len(json.loads(sys.argv[1])))
PY
)
[ "$INSTALL_COUNT" -eq "$INS" ] || die "public installation count mismatch"
printf 'me_username=%s installation_count=%s\n' "$ME_USER" "$INSTALL_COUNT"
printf '%s\n' "public_authenticated_api=PASS"

printf '\n=== 6. REVOKE VALIDATION SESSION ===\n'
REVOKE_JSON=$(python3 - "$REFRESH" <<'PY'
import json,sys
print(json.dumps({"refreshToken":sys.argv[1]}))
PY
)
REV=$(printf '%s' "$REVOKE_JSON" | curl --max-time 20 -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" -X POST "https://$HOSTNAME/api/v1/auth/revoke" --data-binary @-)
[ "$REV" = 204 ] || die "public session revoke failed"
printf '%s\n' "public_test_session_revoked=PASS"
unset ADMIN_PASS LOGIN_JSON LOGIN_RESPONSE TOKEN REFRESH ME_JSON INSTALL_JSON REVOKE_JSON

printf '\n=== 7. PRODUCTION FINAL SAFETY ===\n'
FIMG=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FRUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FMIG=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FLIC=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
[ "$FIMG" = "$IMG" ] || die "production image changed"
[ "$FRUN" = true ] || die "production API stopped"
[ "$FMIG" = "$MIG" ] || die "production migrations changed"
[ "$FLIC" = "$LIC" ] || die "production license count changed"
[ "$FINS" = "$INS" ] || die "production installation count changed"
printf '%s\n' "production_unchanged=PASS"

printf '\n%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7E5 PUBLIC PREVIEW PASSED"
printf '%s\n' "======================================================"
printf '%s\n' "CLOUDFLARE HTTPS ROUTES:            PASS"
printf '%s\n' "PUBLIC ADMIN LOGIN:                 PASS"
printf '%s\n' "PUBLIC AUTHENTICATED API:           PASS"
printf '%s\n' "PREVIEW INSTALLATIONS COUNT:        MATCHED"
printf '%s\n' "PASSWORD CONTENT:                   NOT PRINTED"
printf '%s\n' "PRODUCTION API/DB:                  UNCHANGED"
printf 'REPORT:                             %s\n' "$REPORT"
printf '%s\n' "======================================================"

#!/usr/bin/env bash
# QFLM RECOVERY 7E3
# Preview exposure preflight only. READ-ONLY.

set -u
set -o pipefail
umask 077

PROD_API="qflm-api"
PG="qflm-postgres"
DB="qflm"
EXPECTED_IMAGE="qflm-api:recovery6f3-candidate"
API_IMAGE="qflm-api:recovery7e2-candidate"
GUI_IMAGE="qflm-admin-web:recovery7e2-candidate"
CF_HOSTNAME="lc.quikefix.info"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="/opt/qflm/backups/recovery7e3-preflight-$STAMP.txt"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p /opt/qflm/backups
exec > >(tee "$REPORT") 2>&1

printf '%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7E3"
printf '%s\n' " PREVIEW / CLOUDFLARE EXPOSURE PREFLIGHT"
printf '%s\n' " READ-ONLY"
printf '%s\n' "======================================================"

printf '\n=== 1. PRODUCTION SAFETY BASELINE ===\n'
IMG=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
RUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
LIC=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
INS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
printf 'image=%s running=%s migrations=%s licenses=%s installations=%s\n' "$IMG" "$RUN" "$MIG" "$LIC" "$INS"
[ "$IMG" = "$EXPECTED_IMAGE" ] || die "unexpected production API image"
[ "$RUN" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"
printf '%s\n' "production_baseline=PASS"

printf '\n=== 2. RECOVERY 7E2 CANDIDATE IMAGES ===\n'
docker image inspect "$API_IMAGE" >/dev/null 2>&1 || die "Recovery 7E2 API image missing"
docker image inspect "$GUI_IMAGE" >/dev/null 2>&1 || die "Recovery 7E2 GUI image missing"
printf '%s\n' "recovery7e2_candidate_images=PASS"

printf '\n=== 3. CURRENT HOST ADDRESSES ===\n'
ip -4 -o addr show scope global | awk '{print $2" "$4}' | sort -u
DEFAULT_ROUTE=$(ip -4 route show default | head -n1 || true)
printf 'default_route=%s\n' "$DEFAULT_ROUTE"

ORIGIN_CANDIDATE=$(ip -4 -o addr show dev ens18 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)
if [ -z "$ORIGIN_CANDIDATE" ]; then
  ORIGIN_CANDIDATE=$(ip -4 -o addr show scope global | awk '$2!="docker0"{print $4}' | cut -d/ -f1 | head -n1 || true)
fi
[ -n "$ORIGIN_CANDIDATE" ] || die "no current IPv4 origin candidate found"
printf 'origin_candidate=%s\n' "$ORIGIN_CANDIDATE"
printf '%s\n' "host_network_inventory=PASS"

printf '\n=== 4. PORT 8088 STATUS ===\n'
if ss -ltnH | awk '{print $4}' | grep -Eq '(^|:)8088$'; then
  printf '%s\n' "port_8088=IN_USE"
  ss -ltnp | grep ':8088' || true
else
  printf '%s\n' "port_8088=FREE"
fi

printf '\n=== 5. CLOUDFLARED INVENTORY ===\n'
if command -v cloudflared >/dev/null 2>&1; then
  printf 'cloudflared_binary=%s\n' "$(command -v cloudflared)"
  cloudflared --version 2>/dev/null || true
else
  printf '%s\n' "cloudflared_binary=MISSING"
fi

if systemctl list-unit-files 2>/dev/null | grep -q '^cloudflared\.service'; then
  printf 'cloudflared_service=%s\n' "$(systemctl is-active cloudflared 2>/dev/null || true)"
else
  printf '%s\n' "cloudflared_service=MISSING"
fi

printf '\n=== 6. CLOUDFLARE CONFIG INVENTORY (NO SECRET CONTENT) ===\n'
FOUND_CFG=0
for f in /etc/cloudflared/config.yml /etc/cloudflared/config.yaml /root/.cloudflared/config.yml /root/.cloudflared/config.yaml; do
  if [ -f "$f" ]; then
    FOUND_CFG=1
    printf 'config_file=%s\n' "$f"
    grep -nE '^[[:space:]]*(- hostname:|hostname:|service:|tunnel:)' "$f" 2>/dev/null | sed -E 's/(credentials-file:).*/\1 [REDACTED]/' || true
    if grep -Fq "$CF_HOSTNAME" "$f"; then
      printf 'hostname_%s=FOUND_IN_CONFIG\n' "$CF_HOSTNAME"
    fi
  fi
done
[ "$FOUND_CFG" -eq 1 ] || printf '%s\n' "cloudflare_config=NOT_FOUND"

printf '\n=== 7. DNS / HTTPS OBSERVATION ===\n'
if command -v getent >/dev/null 2>&1; then
  printf 'dns_%s=' "$CF_HOSTNAME"
  getent ahostsv4 "$CF_HOSTNAME" 2>/dev/null | awk 'NR==1{print $1}' || true
fi
HTTP=$(curl --max-time 12 -sS -o /dev/null -w '%{http_code}' "https://$CF_HOSTNAME/" 2>/dev/null || true)
printf 'https_%s_http=%s\n' "$CF_HOSTNAME" "$HTTP"

printf '\n=== 8. PRODUCTION FINAL NO-MUTATION CHECK ===\n'
FIMG=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FRUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FMIG=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FLIC=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
[ "$FIMG" = "$IMG" ] || die "production image changed"
[ "$FRUN" = true ] || die "production API stopped"
[ "$FMIG" = "$MIG" ] || die "production migrations changed"
[ "$FLIC" = "$LIC" ] || die "production licenses changed"
[ "$FINS" = "$INS" ] || die "production installations changed"
printf '%s\n' "production_unchanged=PASS"

printf '\n%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7E3 PREFLIGHT PASSED"
printf '%s\n' "======================================================"
printf 'ORIGIN CANDIDATE:                   %s\n' "$ORIGIN_CANDIDATE"
printf '%s\n' "PORT 8088:                          OBSERVED ONLY"
printf '%s\n' "CLOUDFLARE/TUNNEL:                  INVENTORIED ONLY"
printf '%s\n' "RECOVERY 7E2 IMAGES:                VERIFIED"
printf '%s\n' "PRODUCTION API/DB:                  UNCHANGED"
printf 'REPORT:                             %s\n' "$REPORT"
printf '%s\n' "NEXT: RECOVERY 7E4 - CREATE SAFE PREVIEW USING VERIFIED CURRENT ORIGIN/TUNNEL"
printf '%s\n' "======================================================"

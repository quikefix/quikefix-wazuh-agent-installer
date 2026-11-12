#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

HOSTNAME="lc.quikefix.info"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="/opt/qflm/backups/recovery7e5-tunnel-discovery-$STAMP.txt"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p /opt/qflm/backups
exec > >(tee "$REPORT") 2>&1

printf '%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7E5"
printf '%s\n' " CLOUDFLARE TUNNEL IDENTITY DISCOVERY"
printf '%s\n' " READ-ONLY / SECRET CONTENT NEVER PRINTED"
printf '%s\n' "======================================================"

printf '\n=== 1. LOCAL PREVIEW STATUS ===\n'
if docker inspect qflm-admin-web-gui-preview >/dev/null 2>&1; then
  printf 'preview_gui_running=%s\n' "$(docker inspect qflm-admin-web-gui-preview --format='{{.State.Running}}')"
else
  printf '%s\n' "preview_gui=MISSING"
fi
if docker inspect qflm-api-gui-preview >/dev/null 2>&1; then
  printf 'preview_api_running=%s\n' "$(docker inspect qflm-api-gui-preview --format='{{.State.Running}}')"
else
  printf '%s\n' "preview_api=MISSING"
fi

printf '\n=== 2. CLOUDFLARED BINARY ===\n'
command -v cloudflared >/dev/null 2>&1 || die "cloudflared binary missing"
cloudflared --version 2>/dev/null || true

printf '\n=== 3. DNS TUNNEL TARGET OBSERVATION ===\n'
if command -v dig >/dev/null 2>&1; then
  CNAME="$(dig +short CNAME "$HOSTNAME" 2>/dev/null | head -n1 || true)"
  A="$(dig +short A "$HOSTNAME" 2>/dev/null | paste -sd, - || true)"
  [ -n "$CNAME" ] && printf 'cname=%s\n' "$CNAME" || printf '%s\n' "cname=NONE"
  [ -n "$A" ] && printf 'a_records=%s\n' "$A" || printf '%s\n' "a_records=NONE"
else
  printf '%s\n' "dig=MISSING"
fi

printf '\n=== 4. CLOUDFLARE CONFIG / CREDENTIAL FILE NAMES ONLY ===\n'
FOUND=0
for d in /etc/cloudflared /root/.cloudflared /home/*/.cloudflared; do
  [ -d "$d" ] || continue
  FOUND=1
  printf 'directory=%s\n' "$d"
  find "$d" -maxdepth 2 -type f -printf '%p\n' 2>/dev/null | sort
done
[ "$FOUND" -eq 1 ] || printf '%s\n' "cloudflared_directories=NONE"

printf '\n=== 5. SYSTEMD REMNANTS ===\n'
systemctl list-unit-files 2>/dev/null | grep -E '^cloudflared|qflm.*tunnel|tunnel.*qflm' || true
find /etc/systemd/system /lib/systemd/system -maxdepth 2 -type f \( -iname '*cloudflared*' -o -iname '*qflm*tunnel*' -o -iname '*tunnel*qflm*' \) -printf '%p\n' 2>/dev/null | sort || true

printf '\n=== 6. RUNNING PROCESS CHECK ===\n'
pgrep -a cloudflared 2>/dev/null | sed -E 's/(--token[ =]+)[^ ]+/\1[REDACTED]/g' || printf '%s\n' "cloudflared_process=NONE"

printf '\n=== 7. CLOUDFLARE CERT PRESENCE ===\n'
CERT_FOUND=0
for f in /root/.cloudflared/cert.pem /etc/cloudflared/cert.pem /home/*/.cloudflared/cert.pem; do
  [ -f "$f" ] || continue
  CERT_FOUND=1
  printf 'cert_file=%s\n' "$f"
done
[ "$CERT_FOUND" -eq 1 ] || printf '%s\n' "cloudflare_cert=NONE"

printf '\n=== 8. TUNNEL LIST IF AUTH CERT EXISTS ===\n'
if [ "$CERT_FOUND" -eq 1 ]; then
  cloudflared tunnel list 2>&1 | sed -E 's/[A-Za-z0-9_-]{40,}/[REDACTED]/g' || true
else
  printf '%s\n' "tunnel_list=SKIPPED_NO_CERT"
fi

printf '\n=== 9. CURRENT HTTPS OBSERVATION ===\n'
HTTP="$(curl --max-time 15 -sS -o /dev/null -w '%{http_code}' "https://$HOSTNAME/" 2>/dev/null || true)"
printf 'https_http=%s\n' "$HTTP"

printf '\n%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7E5 DISCOVERY COMPLETE"
printf '%s\n' "======================================================"
printf '%s\n' "NO FILE CONTENTS:                   PRINTED"
printf '%s\n' "NO TOKENS:                          PRINTED"
printf '%s\n' "NO CLOUDFLARE CHANGES:              MADE"
printf 'REPORT:                             %s\n' "$REPORT"
printf '%s\n' "======================================================"

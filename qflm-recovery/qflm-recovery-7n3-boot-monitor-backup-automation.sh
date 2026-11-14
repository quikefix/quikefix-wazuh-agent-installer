#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
MON="$ROOT/ops/monitoring"
OPS_BACKUP="$ROOT/ops/backup"
DAILY="/opt/qflm/backups/daily"

PROD_API="qflm-api"
PROD_GUI="qflm-admin-web-production"
PG="qflm-postgres"
REDIS="qflm-redis"
SIGNING="qflm-signing"

EXPECTED_API_IMAGE="qflm-api:recovery7k2-production"
EXPECTED_GUI_IMAGE="qflm-admin-web:recovery7l3-production"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/opt/qflm/backups/recovery7n3-boot-monitor-backup-$STAMP"
REPORT="$OUT/recovery7n3-boot-monitor-backup-report.txt"
MANIFEST="$OUT/recovery7n3-boot-monitor-backup.manifest"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p "$OUT" "$MON" "$OPS_BACKUP" "$DAILY"
chmod 700 "$DAILY"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7N3"
echo " BOOT PERSISTENCE / MONITORING / BACKUP AUTOMATION"
echo "======================================================"

echo
echo "=== 1. PRODUCTION SAFETY BASELINE ==="

API_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
GUI_IMAGE=$(docker inspect "$PROD_GUI" --format='{{.Config.Image}}') || die "production GUI missing"
API_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
GUI_RUNNING=$(docker inspect "$PROD_GUI" --format='{{.State.Running}}')

[ "$API_IMAGE" = "$EXPECTED_API_IMAGE" ] || die "unexpected production API image"
[ "$GUI_IMAGE" = "$EXPECTED_GUI_IMAGE" ] || die "unexpected production GUI image"
[ "$API_RUNNING" = true ] || die "production API not running"
[ "$GUI_RUNNING" = true ] || die "production GUI not running"

MIG=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
USERS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_users;' | xargs)
ROLES=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PERMS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
LICENSES=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM licenses;' | xargs)
INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM installations;' | xargs)

[ "$MIG" = 5 ] || die "unexpected migration count"
[ "$PERMS" = 22 ] || die "unexpected permission count"

echo "production_baseline=PASS"

echo
echo "=== 2. PRE-CHANGE DATABASE BACKUP ==="

PRE="$OUT/qflm-pre-7n3.dump"
docker exec "$PG" pg_dump -U qflm -Fc -d qflm > "$PRE" || die "pre-change database backup failed"
[ -s "$PRE" ] || die "pre-change database backup empty"
cat "$PRE" | docker exec -i "$PG" pg_restore -l >/dev/null || die "pre-change database backup validation failed"
PRE_SHA=$(sha256sum "$PRE" | awk '{print $1}')

echo "prechange_backup=$PRE"
echo "prechange_backup_sha256=$PRE_SHA"
echo "prechange_backup=PASS"

echo
echo "=== 3. ENABLE CONTAINER BOOT PERSISTENCE ==="

docker update --restart unless-stopped "$PROD_API" >/dev/null || die "failed to update API restart policy"
docker update --restart unless-stopped "$PROD_GUI" >/dev/null || die "failed to update GUI restart policy"

for c in "$PROD_API" "$PROD_GUI" "$PG" "$REDIS" "$SIGNING"; do
  policy=$(docker inspect "$c" --format='{{.HostConfig.RestartPolicy.Name}}')
  [ "$policy" = "unless-stopped" ] || die "unexpected restart policy for $c: $policy"
  echo "$c restart_policy=$policy"
done

echo "container_boot_persistence=PASS"

echo
echo "=== 4. INSTALL DAILY BACKUP SCRIPT ==="

cat > "$OPS_BACKUP/qflm-daily-backup.sh" <<'EOF'
#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

PG="qflm-postgres"
DB="qflm"
DEST="/opt/qflm/backups/daily"

mkdir -p "$DEST"
chmod 700 "$DEST"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMP="$DEST/.qflm-$STAMP.dump.tmp"
FINAL="$DEST/qflm-$STAMP.dump"
HASH="$FINAL.sha256"

cleanup(){ rm -f "$TMP"; }
trap cleanup EXIT

docker inspect "$PG" >/dev/null 2>&1 || { echo "ERROR postgres container missing"; exit 1; }
[ "$(docker inspect "$PG" --format='{{.State.Running}}')" = true ] || { echo "ERROR postgres not running"; exit 1; }

docker exec "$PG" pg_dump -U qflm -Fc -d "$DB" > "$TMP" || { echo "ERROR pg_dump failed"; exit 1; }
[ -s "$TMP" ] || { echo "ERROR backup empty"; exit 1; }

cat "$TMP" | docker exec -i "$PG" pg_restore -l >/dev/null || { echo "ERROR pg_restore validation failed"; exit 1; }

mv "$TMP" "$FINAL"
sha256sum "$FINAL" > "$HASH"
chmod 600 "$FINAL" "$HASH"

find "$DEST" -maxdepth 1 -type f -name 'qflm-*.dump' -mtime +14 -delete
find "$DEST" -maxdepth 1 -type f -name 'qflm-*.dump.sha256' -mtime +14 -delete

echo "OK backup=$FINAL"
echo "OK sha256=$(awk '{print $1}' "$HASH")"
EOF

chmod 700 "$OPS_BACKUP/qflm-daily-backup.sh"
"$OPS_BACKUP/qflm-daily-backup.sh" || die "initial automated backup failed"

LATEST_BACKUP=$(find "$DAILY" -maxdepth 1 -type f -name 'qflm-*.dump' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
[ -n "$LATEST_BACKUP" ] || die "daily backup not created"
cat "$LATEST_BACKUP" | docker exec -i "$PG" pg_restore -l >/dev/null || die "daily backup validation failed"

echo "backup_script=PASS"

echo
echo "=== 5. HARDEN HEALTH CHECK WITH BACKUP FRESHNESS ==="

cat > "$MON/qflm-health-check.sh" <<'EOF'
#!/usr/bin/env bash
set -u
set -o pipefail

fail=0
DAILY="/opt/qflm/backups/daily"

check_container() {
  local c="$1"
  local running
  running="$(docker inspect "$c" --format='{{.State.Running}}' 2>/dev/null || echo false)"
  if [ "$running" = true ]; then
    echo "OK container=$c"
  else
    echo "CRITICAL container=$c"
    fail=1
  fi
}

check_container qflm-postgres
check_container qflm-redis
check_container qflm-signing
check_container qflm-api
check_container qflm-admin-web-production

if docker run --rm --network qflm_backend curlimages/curl:8.16.0 -fsS http://qflm-api:8080/health/live >/dev/null 2>&1; then
  echo "OK api_live"
else
  echo "CRITICAL api_live"
  fail=1
fi

if docker run --rm --network qflm_backend curlimages/curl:8.16.0 -fsS http://qflm-api:8080/health/ready >/dev/null 2>&1; then
  echo "OK api_ready"
else
  echo "CRITICAL api_ready"
  fail=1
fi

code="$(curl -L -s -o /dev/null -w '%{http_code}' https://lc.quikefix.info/ || true)"
if [ "$code" = 200 ]; then
  echo "OK public_gui=$code"
else
  echo "CRITICAL public_gui=$code"
  fail=1
fi

disk="$(df -P /opt | awk 'NR==2 {gsub("%","",$5); print $5}')"
if [ "$disk" -ge 90 ]; then
  echo "CRITICAL disk_percent=$disk"
  fail=1
elif [ "$disk" -ge 80 ]; then
  echo "WARNING disk_percent=$disk"
else
  echo "OK disk_percent=$disk"
fi

latest="$(find "$DAILY" -maxdepth 1 -type f -name 'qflm-*.dump' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 || true)"
if [ -z "$latest" ]; then
  echo "CRITICAL backup_missing"
  fail=1
else
  epoch="$(printf '%s\n' "$latest" | awk '{print $1}' | cut -d. -f1)"
  path="$(printf '%s\n' "$latest" | cut -d' ' -f2-)"
  age=$(( $(date +%s) - epoch ))
  if [ "$age" -gt 93600 ]; then
    echo "CRITICAL backup_stale_seconds=$age path=$path"
    fail=1
  else
    echo "OK backup_age_seconds=$age path=$path"
  fi
fi

exit "$fail"
EOF

chmod 755 "$MON/qflm-health-check.sh"
"$MON/qflm-health-check.sh" || die "enhanced health check failed"

echo "enhanced_health_check=PASS"

echo
echo "=== 6. INSTALL SYSTEMD HEALTH MONITOR ==="

cat > /etc/systemd/system/qflm-health-monitor.service <<EOF
[Unit]
Description=QFLM Production Health Check
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$MON/qflm-health-check.sh
User=root
Group=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
EOF

cat > /etc/systemd/system/qflm-health-monitor.timer <<'EOF'
[Unit]
Description=Run QFLM production health check every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo "health_systemd_units=PASS"

echo
echo "=== 7. INSTALL SYSTEMD DAILY BACKUP ==="

cat > /etc/systemd/system/qflm-daily-backup.service <<EOF
[Unit]
Description=QFLM Daily PostgreSQL Backup
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$OPS_BACKUP/qflm-daily-backup.sh
User=root
Group=root
NoNewPrivileges=true
PrivateTmp=true
EOF

cat > /etc/systemd/system/qflm-daily-backup.timer <<'EOF'
[Unit]
Description=Run QFLM daily PostgreSQL backup

[Timer]
OnCalendar=*-*-* 02:15:00 UTC
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now qflm-health-monitor.timer >/dev/null
systemctl enable --now qflm-daily-backup.timer >/dev/null

systemctl is-enabled qflm-health-monitor.timer | grep -qx enabled || die "health timer not enabled"
systemctl is-active qflm-health-monitor.timer | grep -qx active || die "health timer not active"
systemctl is-enabled qflm-daily-backup.timer | grep -qx enabled || die "backup timer not enabled"
systemctl is-active qflm-daily-backup.timer | grep -qx active || die "backup timer not active"

echo "systemd_automation=PASS"

echo
echo "=== 8. EXECUTE MONITORING SERVICE NOW ==="

systemctl start qflm-health-monitor.service || die "health monitor service failed"
systemctl show qflm-health-monitor.service -p Result --value | grep -qx success || die "health monitor result not successful"
systemctl list-timers qflm-health-monitor.timer qflm-daily-backup.timer --no-pager

echo "active_monitoring=PASS"

echo
echo "=== 9. VERIFY PRODUCTION HEALTH ==="

docker run --rm --network qflm_backend curlimages/curl:8.16.0 -fsS http://qflm-api:8080/health/live >/dev/null || die "API live failed"
docker run --rm --network qflm_backend curlimages/curl:8.16.0 -fsS http://qflm-api:8080/health/ready >/dev/null || die "API ready failed"

for route in / /login /customers /products /licenses /installations /offline /security /audit /system; do
  code=$(curl -L -s -o /dev/null -w '%{http_code}' "https://lc.quikefix.info$route" || true)
  [ "$code" = 200 ] || die "public route failed: $route -> $code"
done

echo "production_health=PASS"

echo
echo "=== 10. FINAL DATABASE NO-MUTATION CHECK ==="

FINAL_MIG=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_USERS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_users;' | xargs)
FINAL_ROLES=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
FINAL_PERMS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
FINAL_LICENSES=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINAL_INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM installations;' | xargs)

[ "$FINAL_MIG" = "$MIG" ] || die "migration count changed"
[ "$FINAL_USERS" = "$USERS" ] || die "user count changed"
[ "$FINAL_ROLES" = "$ROLES" ] || die "role count changed"
[ "$FINAL_PERMS" = "$PERMS" ] || die "permission count changed"
[ "$FINAL_LICENSES" = "$LICENSES" ] || die "license count changed"
[ "$FINAL_INSTALLATIONS" = "$INSTALLATIONS" ] || die "installation count changed"

FINAL_API_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_GUI_IMAGE=$(docker inspect "$PROD_GUI" --format='{{.Config.Image}}')

[ "$FINAL_API_IMAGE" = "$API_IMAGE" ] || die "API image changed"
[ "$FINAL_GUI_IMAGE" = "$GUI_IMAGE" ] || die "GUI image changed"

echo "production_no_mutation=PASS"

echo
echo "=== 11. WRITE 7N3 MANIFEST ==="

API_POLICY=$(docker inspect "$PROD_API" --format='{{.HostConfig.RestartPolicy.Name}}')
GUI_POLICY=$(docker inspect "$PROD_GUI" --format='{{.HostConfig.RestartPolicy.Name}}')
LATEST_SHA=$(sha256sum "$LATEST_BACKUP" | awk '{print $1}')

cat > "$MANIFEST" <<EOF
QFLM_OPERATIONS_AUTOMATION=RECOVERY_7N3
UTC=$STAMP
PRODUCTION_API_IMAGE=$API_IMAGE
PRODUCTION_GUI_IMAGE=$GUI_IMAGE
PRODUCTION_API_RESTART_POLICY=$API_POLICY
PRODUCTION_GUI_RESTART_POLICY=$GUI_POLICY
HEALTH_TIMER=qflm-health-monitor.timer
HEALTH_TIMER_ENABLED=$(systemctl is-enabled qflm-health-monitor.timer)
HEALTH_TIMER_ACTIVE=$(systemctl is-active qflm-health-monitor.timer)
BACKUP_TIMER=qflm-daily-backup.timer
BACKUP_TIMER_ENABLED=$(systemctl is-enabled qflm-daily-backup.timer)
BACKUP_TIMER_ACTIVE=$(systemctl is-active qflm-daily-backup.timer)
LATEST_BACKUP=$LATEST_BACKUP
LATEST_BACKUP_SHA256=$LATEST_SHA
DATABASE_MIGRATIONS=$MIG
DATABASE_PERMISSIONS=$PERMS
PUBLIC_URL=https://lc.quikefix.info
EOF

chmod 400 "$MANIFEST"

echo "manifest=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7N3 PASSED"
echo "======================================================"
echo "API BOOT PERSISTENCE:               unless-stopped"
echo "GUI BOOT PERSISTENCE:               unless-stopped"
echo "HEALTH MONITOR TIMER:               ENABLED / ACTIVE"
echo "HEALTH MONITOR INTERVAL:            5 MINUTES"
echo "DAILY DB BACKUP TIMER:              ENABLED / ACTIVE"
echo "DAILY DB BACKUP TIME:               02:15 UTC"
echo "BACKUP RETENTION:                   14 DAYS"
echo "INITIAL AUTOMATED BACKUP:           VALIDATED"
echo "BACKUP FRESHNESS MONITORING:        ACTIVE"
echo "PRODUCTION API/GUI/DB:              HEALTHY / UNCHANGED"
echo "MANIFEST:                           $MANIFEST"
echo "REPORT:                             $REPORT"
echo "NEXT: RECOVERY 7N4 - CONTROLLED RESTART / FINAL OPERATIONS FREEZE"
echo "======================================================"

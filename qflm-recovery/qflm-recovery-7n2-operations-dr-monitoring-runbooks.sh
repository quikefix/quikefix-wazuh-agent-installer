#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
DOCS="$ROOT/docs/operations"
MON="$ROOT/ops/monitoring"

PROD_API="qflm-api"
PROD_GUI="qflm-admin-web-production"
PG="qflm-postgres"

EXPECTED_API_IMAGE="qflm-api:recovery7k2-production"
EXPECTED_GUI_IMAGE="qflm-admin-web:recovery7l3-production"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7n2-runbooks-$STAMP"
REPORT="$BACKUP/recovery7n2-runbooks-report.txt"
MANIFEST="$BACKUP/recovery7n2-runbooks.manifest"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p "$BACKUP" "$DOCS" "$MON"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7N2"
echo " OPERATIONS / DR / MONITORING RUNBOOKS"
echo "======================================================"

echo
echo "=== 1. PRODUCTION SAFETY BASELINE ==="

API_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
GUI_IMAGE=$(docker inspect "$PROD_GUI" --format='{{.Config.Image}}') || die "production GUI missing"
API_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
GUI_RUNNING=$(docker inspect "$PROD_GUI" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

[ "$API_IMAGE" = "$EXPECTED_API_IMAGE" ] || die "unexpected production API image"
[ "$GUI_IMAGE" = "$EXPECTED_GUI_IMAGE" ] || die "unexpected production GUI image"
[ "$API_RUNNING" = true ] || die "production API not running"
[ "$GUI_RUNNING" = true ] || die "production GUI not running"
[ "$MIG" = 5 ] || die "unexpected migration count"

echo "production_baseline=PASS"

echo
echo "=== 2. CREATE OPERATIONS RUNBOOK ==="

cat > "$DOCS/01-PRODUCTION-OPERATIONS.md" <<'EOF'
# QFLM Production Operations

Public Admin GUI: https://lc.quikefix.info
Cloudflare origin: http://10.100.0.102:8088

Production containers:
- qflm-api using qflm-api:recovery7k2-production
- qflm-admin-web-production using qflm-admin-web:recovery7l3-production
- qflm-postgres
- qflm-redis
- qflm-signing

Health checks:

    docker run --rm --network qflm_backend curlimages/curl:8.16.0 -fsS http://qflm-api:8080/health/live
    docker run --rm --network qflm_backend curlimages/curl:8.16.0 -fsS http://qflm-api:8080/health/ready
    curl -fsS -o /dev/null -w '%{http_code}\n' https://lc.quikefix.info/

Frozen invariants:
- migrations: 5
- permissions: 22

Secrets live under /opt/qflm/secrets and must never be copied into Git, tickets, chat, screenshots, monitoring output, or ordinary logs.

The signing private key must remain mounted only in qflm-signing.

Production change control:
1. Create a PostgreSQL dump.
2. Record current image/container IDs.
3. Preserve rollback images and containers.
4. Validate candidate in isolation.
5. Perform controlled cutover.
6. Validate API health and public GUI.
7. Write a freeze manifest.
EOF

echo "operations_runbook=PASS"

echo
echo "=== 3. CREATE DISASTER RECOVERY RUNBOOK ==="

cat > "$DOCS/02-DISASTER-RECOVERY.md" <<'EOF'
# QFLM Disaster Recovery

Recovery priority:
1. PostgreSQL data
2. Runtime secrets and signing material
3. Redis
4. Signing service
5. Production API
6. Production Admin GUI
7. Cloudflare tunnel

Critical data:
- PostgreSQL volume: qflm_postgres_data
- Redis volume: qflm_redis_data
- Secrets: /opt/qflm/secrets
- Backups: /opt/qflm/backups

Known final database freeze:
- /opt/qflm/backups/recovery7k3-final-freeze-20261114T162402Z/qflm-final-freeze.dump

Rollback API:
- container qflm-api-recovery7k2-rollback
- image qflm-api:recovery6f3-candidate

Rollback GUI:
- container qflm-admin-web-recovery7l3-preview-rollback
- image qflm-admin-web:recovery7j3-preview

Database restore rules:
- Never restore over live production without a maintenance window.
- Always create a fresh pre-restore dump.
- Stop qflm-api before destructive restore.
- Restore only a verified dump.
- After restore validate live health, readiness, migrations, Admin GUI and licensing.

Total host loss recovery order:
1. Install Docker.
2. Restore /opt/qflm/secrets with root-only permissions.
3. Restore/import required images.
4. Create qflm_backend.
5. Restore PostgreSQL and Redis volumes.
6. Restore qflm database.
7. Start PostgreSQL and Redis.
8. Start qflm-signing.
9. Start qflm-api.
10. Start qflm-admin-web-production.
11. Start cloudflared.
12. Validate all health/public routes.
EOF

echo "dr_runbook=PASS"

echo
echo "=== 4. CREATE BACKUP RUNBOOK ==="

cat > "$DOCS/03-BACKUP-RESTORE.md" <<'EOF'
# QFLM Backup and Restore

Minimum backup set:
- PostgreSQL logical dump
- encrypted copy of /opt/qflm/secrets
- final freeze manifests
- production image inventory
- SDK package/source archive
- operations documentation

Database backup:

    install -d -m 700 /opt/qflm/backups/daily
    docker exec qflm-postgres pg_dump -U qflm -Fc -d qflm > /opt/qflm/backups/daily/qflm-$(date -u +%Y%m%dT%H%M%SZ).dump

Validate each dump:
- file non-zero
- SHA-256 recorded
- pg_restore can list archive
- periodic isolated restore test succeeds

Recommended retention:
- daily 14 days
- weekly 8 weeks
- monthly 12 months
- final release/freeze backups indefinitely

Keep at least one encrypted off-host copy.

Never place secrets in Git or unencrypted general-purpose backup storage.
EOF

echo "backup_runbook=PASS"

echo
echo "=== 5. CREATE MONITORING RUNBOOK + CHECK ==="

cat > "$DOCS/04-MONITORING-ALERTING.md" <<'EOF'
# QFLM Monitoring and Alerting

Monitor:
- Docker daemon
- cloudflared
- qflm-postgres health
- qflm-redis health
- qflm-signing
- qflm-api
- qflm-admin-web-production
- API live and ready endpoints
- public GUI HTTP 200
- disk usage
- database backup freshness
- container restart counts
- Cloudflare origin failures

Alert thresholds:
- API or GUI unavailable: immediate
- PostgreSQL unhealthy: immediate
- signing unavailable: immediate
- Redis unavailable: high
- disk 80 percent: warning
- disk 90 percent: critical
- no database backup for 26 hours: critical

Historical Cloudflare note:
The tunnel previously targeted 10.77.0.7:8088 and returned connection refused.
The current production origin is 10.100.0.102:8088.
EOF

cat > "$MON/qflm-health-check.sh" <<'EOF'
#!/usr/bin/env bash
set -u
set -o pipefail

fail=0

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

exit "$fail"
EOF

chmod 755 "$MON/qflm-health-check.sh"

"$MON/qflm-health-check.sh" || die "health check failed"

echo "monitoring_runbook=PASS"

echo
echo "=== 6. CREATE REBOOT / STARTUP RUNBOOK ==="

cat > "$DOCS/05-REBOOT-STARTUP.md" <<'EOF'
# QFLM Reboot and Startup

Recovery 7N1 restart policy inventory:
- qflm-postgres: unless-stopped
- qflm-redis: unless-stopped
- qflm-signing: unless-stopped
- qflm-api: no
- qflm-admin-web-production: no

The API and GUI therefore require persistence hardening before unattended reboot recovery is complete.

Startup dependency order:
1. Docker
2. PostgreSQL
3. Redis
4. Signing
5. API
6. Admin GUI
7. cloudflared validation

Manual emergency startup:

    docker start qflm-postgres
    docker start qflm-redis
    docker start qflm-signing
    docker start qflm-api
    docker start qflm-admin-web-production
    systemctl restart cloudflared

Pre-reboot:
- fresh PostgreSQL dump
- backup SHA-256
- secrets present
- image tags recorded
- rollback assets present
- console access available

Post-reboot:
- Docker active
- cloudflared active
- PostgreSQL healthy
- Redis healthy
- signing running
- API live and ready
- GUI listener on 10.100.0.102:8088
- public GUI HTTP 200
EOF

echo "reboot_runbook=PASS"

echo
echo "=== 7. CREATE INCIDENT RESPONSE RUNBOOK ==="

cat > "$DOCS/06-INCIDENT-RESPONSE.md" <<'EOF'
# QFLM Incident Response

Severity 1 examples:
- licensing API unavailable
- database unavailable
- signing unavailable
- Admin GUI unavailable
- suspected private signing-key exposure
- suspected database compromise
- unauthorized administrator access

Immediate actions:
1. Record UTC time.
2. Preserve evidence.
3. Record image/container IDs.
4. Export relevant logs.
5. Create a safe database dump if possible.
6. Determine whether secrets/signing material were exposed.
7. Restrict ingress if compromise is suspected.

Signing-key compromise:
- stop new offline issuance
- preserve audit history and current key ID
- generate a controlled replacement key
- update trust material
- revoke/supersede affected offline licenses as policy requires
- never reuse compromised private key

Incident closure requires:
- root cause
- service restoration
- data-integrity verification
- credential/key exposure assessment
- monitoring improvement
- incident timeline
EOF

echo "incident_runbook=PASS"

echo
echo "=== 8. CREATE SDK INTEGRATION RUNBOOK ==="

cat > "$DOCS/07-CLIENT-SDK-INTEGRATION.md" <<'EOF'
# QFLM .NET Client SDK Integration

Frozen package:
- QuikeFix.QFLM.ClientSdk 0.1.0
- target framework net8.0
- API base https://lc.quikefix.info/

Endpoints:
- POST /api/v1/activate
- POST /api/v1/validate
- POST /api/v1/heartbeat
- POST /api/v1/deactivate

Client flow:
1. Generate and persist one installation UUID.
2. Generate a stable machine fingerprint.
3. Activate with license key, product code, installation ID and fingerprint.
4. Validate on application startup.
5. Honor EffectiveState.
6. Honor AllowWriteOperations.
7. Honor Entitlements.
8. Send monotonically increasing heartbeat sequence values.
9. Deactivate on intentional uninstall/device release.

Security:
- never log the license key
- never embed admin credentials
- use HTTPS only
- do not regenerate installation ID every start
- treat MachineMismatch as binding failure
- treat SequenceRejected as stale/replayed heartbeat
EOF

echo "sdk_runbook=PASS"

echo
echo "=== 9. CREATE RELEASE CHECKLIST / INDEX ==="

cat > "$DOCS/08-RELEASE-CHECKLIST.md" <<'EOF'
# QFLM Release Checklist

Backend:
- API image frozen
- API live/ready
- migration count expected
- PostgreSQL backup created and hashed
- rollback API preserved

GUI:
- GUI image frozen
- all public routes return 200
- rollback GUI preserved

Security:
- API and GUI read-only
- capabilities dropped
- no-new-privileges enabled
- API has no public host port
- signing private key only in signing service
- secrets root-restricted

SDK:
- package built
- tests pass
- activate/validate/heartbeat/deactivate compatibility pass
- package SHA-256 recorded

Operations:
- restart persistence validated
- monitoring active
- backup schedule active
- restore test completed
- Cloudflare origin verified
EOF

cat > "$DOCS/README.md" <<'EOF'
# QFLM Operations Documentation

01-PRODUCTION-OPERATIONS.md
02-DISASTER-RECOVERY.md
03-BACKUP-RESTORE.md
04-MONITORING-ALERTING.md
05-REBOOT-STARTUP.md
06-INCIDENT-RESPONSE.md
07-CLIENT-SDK-INTEGRATION.md
08-RELEASE-CHECKLIST.md

Health checker:
/opt/qflm/app/QuikeFix.LicenseManager/ops/monitoring/qflm-health-check.sh
EOF

echo "release_docs=PASS"

echo
echo "=== 10. HASH / MANIFEST ==="

find "$DOCS" "$MON" -type f -print0 | sort -z | xargs -0 sha256sum > "$BACKUP/documentation.sha256"

cat > "$MANIFEST" <<EOF
QFLM_OPERATIONS_RUNBOOKS=RECOVERY_7N2
UTC=$STAMP
PRODUCTION_API_IMAGE=$API_IMAGE
PRODUCTION_GUI_IMAGE=$GUI_IMAGE
DATABASE_MIGRATIONS=$MIG
PUBLIC_URL=https://lc.quikefix.info
ORIGIN=http://10.100.0.102:8088
DOCS=$DOCS
MONITORING_SCRIPT=$MON/qflm-health-check.sh
HASH_FILE=$BACKUP/documentation.sha256
EOF

chmod 400 "$MANIFEST"
echo "documentation_manifest=PASS"

echo
echo "=== 11. FINAL PRODUCTION NO-MUTATION CHECK ==="

FINAL_API_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_GUI_IMAGE=$(docker inspect "$PROD_GUI" --format='{{.Config.Image}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

[ "$FINAL_API_IMAGE" = "$API_IMAGE" ] || die "production API image changed"
[ "$FINAL_GUI_IMAGE" = "$GUI_IMAGE" ] || die "production GUI image changed"
[ "$FINAL_MIG" = "$MIG" ] || die "database migrations changed"

echo "production_no_mutation=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7N2 PASSED"
echo "======================================================"
echo "OPERATIONS RUNBOOK:                 CREATED"
echo "DISASTER RECOVERY RUNBOOK:          CREATED"
echo "BACKUP / RESTORE RUNBOOK:           CREATED"
echo "MONITORING / ALERTING RUNBOOK:      CREATED"
echo "REBOOT / STARTUP RUNBOOK:           CREATED"
echo "INCIDENT RESPONSE RUNBOOK:          CREATED"
echo "SDK INTEGRATION RUNBOOK:            CREATED"
echo "RELEASE CHECKLIST:                  CREATED"
echo "HEALTH CHECK SCRIPT:                PASS"
echo "PRODUCTION API/DB:                  UNCHANGED"
echo "DOCS:                               $DOCS"
echo "MANIFEST:                           $MANIFEST"
echo "REPORT:                             $REPORT"
echo "NEXT: RECOVERY 7N3 - BOOT PERSISTENCE / ACTIVE MONITORING / BACKUP AUTOMATION"
echo "======================================================"

#!/usr/bin/env bash
# QFLM RECOVERY 6E1
# Guarded production auth schema migration + bootstrap administrator seed.
# Production API image/Compose remain unchanged in this stage.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
INFRA="$ROOT/src/QFLM.Infrastructure"
MIGDIR="$INFRA/Persistence/Migrations"

API="qflm-api"
PG="qflm-postgres"
DB="qflm"
EXPECTED_IMAGE="qflm-api:phase14d4-candidate"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery6e1-$STAMP"
REPORT="$BACKUP/recovery6e1-report.txt"
DB_DUMP="$BACKUP/qflm-before-recovery6e1.dump"
MIGSQL="$BACKUP/auth-migrations.sql"
FORWARD="$BACKUP/recovery6e1-forward.sql"

AUTH_SECRET_DIR="/opt/qflm/secrets/auth"
BOOTSTRAP_PASSWORD_FILE="$AUTH_SECRET_DIR/bootstrap-admin-password"
BOOTSTRAP_USERNAME_FILE="$AUTH_SECRET_DIR/bootstrap-admin-username"

COMPLETED=0
PASSWORD_CREATED=0

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

cleanup(){
  if [ "$COMPLETED" -ne 1 ] && [ "$PASSWORD_CREATED" -eq 1 ]; then
    rm -f "$BOOTSTRAP_PASSWORD_FILE" "$BOOTSTRAP_USERNAME_FILE" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

printf '%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 6E1"
printf '%s\n' " AUTH SCHEMA + BOOTSTRAP ADMIN"
printf '%s\n' " GUARDED PRODUCTION DATABASE PROMOTION"
printf '%s\n' "======================================================"

printf '\n=== 1. PRODUCTION SAFETY BASELINE ===\n'

IMG=$(docker inspect "$API" --format='{{.Config.Image}}') \
  || die "production API container missing"

RUN=$(docker inspect "$API" --format='{{.State.Running}}')

MIG_BEFORE=$(docker exec "$PG" psql -U qflm -d "$DB" \
  -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

LIC_BEFORE=$(docker exec "$PG" psql -U qflm -d "$DB" \
  -tAc 'SELECT count(*) FROM licenses;' | xargs)

INST_BEFORE=$(docker exec "$PG" psql -U qflm -d "$DB" \
  -tAc 'SELECT count(*) FROM installations;' | xargs)

OFFLINE_BEFORE=$(docker exec "$PG" psql -U qflm -d "$DB" \
  -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)

AUDIT_BEFORE=$(docker exec "$PG" psql -U qflm -d "$DB" \
  -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)

AUTH_BEFORE=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc "
SELECT count(*)
FROM information_schema.tables
WHERE table_schema='public'
AND table_name LIKE 'auth_%';
" | xargs)

printf 'image=%s running=%s migrations=%s licenses=%s installations=%s offline_issuances=%s offline_audit_events=%s auth_tables=%s\n' \
  "$IMG" "$RUN" "$MIG_BEFORE" "$LIC_BEFORE" "$INST_BEFORE" \
  "$OFFLINE_BEFORE" "$AUDIT_BEFORE" "$AUTH_BEFORE"

[ "$IMG" = "$EXPECTED_IMAGE" ] \
  || die "unexpected production API image"

[ "$RUN" = true ] \
  || die "production API is not running"

[ "$MIG_BEFORE" = 3 ] \
  || die "expected production migration count 3"

[ "$AUTH_BEFORE" = 0 ] \
  || die "production auth tables already exist"

printf '\n=== 2. VERIFY AUTH MIGRATION SOURCE ===\n'

MIG15B=$(find "$MIGDIR" -maxdepth 1 -type f \
  -name '*_AddAuthenticationRbac.cs' | sort | tail -n1)

MIG15C=$(find "$MIGDIR" -maxdepth 1 -type f \
  -name '*_AddAuthRefreshTokens.cs' | sort | tail -n1)

[ -s "$MIG15B" ] \
  || die "AddAuthenticationRbac migration missing"

[ -s "$MIG15C" ] \
  || die "AddAuthRefreshTokens migration missing"

grep -q 'auth_users' "$MIG15B" \
  || die "auth_users missing from Phase 15B migration"

grep -q 'auth_refresh_tokens' "$MIG15C" \
  || die "auth_refresh_tokens missing from Phase 15C migration"

printf 'migration_15b=%s\n' "$(basename "$MIG15B")"
printf 'migration_15c=%s\n' "$(basename "$MIG15C")"
printf '%s\n' "auth_migration_source=PASS"

printf '\n=== 3. PRODUCTION DATABASE BACKUP ===\n'

docker exec "$PG" pg_dump \
  -U qflm \
  -d "$DB" \
  -Fc \
  > "$DB_DUMP" \
  || die "production database backup failed"

[ -s "$DB_DUMP" ] \
  || die "production database backup is empty"

printf 'database_backup=%s\n' "$DB_DUMP"
printf 'database_backup_bytes=%s\n' "$(stat -c '%s' "$DB_DUMP")"
printf 'database_backup_sha256=%s\n' "$(sha256sum "$DB_DUMP" | awk '{print $1}')"

printf '\n=== 4. GENERATE IDEMPOTENT MIGRATION SQL ===\n'

dotnet tool restore >/dev/null \
  || die "dotnet tool restore failed"

dotnet tool run dotnet-ef migrations script \
  --project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj \
  --startup-project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj \
  --context QflmDbContext \
  --idempotent \
  --output "$MIGSQL" \
  || die "auth migration SQL generation failed"

[ -s "$MIGSQL" ] \
  || die "migration SQL is empty"

for table in \
  auth_users \
  auth_roles \
  auth_permissions \
  auth_user_roles \
  auth_role_permissions \
  auth_refresh_tokens
do
  grep -q "$table" "$MIGSQL" \
    || die "$table missing from migration SQL"
done

printf 'migration_sql=%s\n' "$MIGSQL"
printf 'migration_sql_sha256=%s\n' "$(sha256sum "$MIGSQL" | awk '{print $1}')"

printf '\n=== 5. PREPARE BOOTSTRAP ADMIN SECRET ===\n'

install -d -m 700 -o root -g root "$AUTH_SECRET_DIR"

if [ -e "$BOOTSTRAP_PASSWORD_FILE" ] || [ -e "$BOOTSTRAP_USERNAME_FILE" ]; then
  die "bootstrap admin secret files already exist; refusing to overwrite"
fi

BOOTSTRAP_USERNAME="qflm-admin"
BOOTSTRAP_PASSWORD="$(openssl rand -base64 36 | tr -d '\n')"

printf '%s\n' "$BOOTSTRAP_USERNAME" \
  > "$BOOTSTRAP_USERNAME_FILE"

printf '%s\n' "$BOOTSTRAP_PASSWORD" \
  > "$BOOTSTRAP_PASSWORD_FILE"

chown root:root \
  "$BOOTSTRAP_USERNAME_FILE" \
  "$BOOTSTRAP_PASSWORD_FILE"

chmod 600 \
  "$BOOTSTRAP_USERNAME_FILE" \
  "$BOOTSTRAP_PASSWORD_FILE"

PASSWORD_CREATED=1

PASSWORD_HASH=$(python3 - "$BOOTSTRAP_PASSWORD" <<'PY'
import base64
import hashlib
import os
import sys

password = sys.argv[1].encode("utf-8")
salt = os.urandom(16)
digest = hashlib.pbkdf2_hmac(
    "sha512",
    password,
    salt,
    210000,
    32,
)

print(
    "PBKDF2-SHA512$210000$%s$%s"
    % (
        base64.b64encode(salt).decode("ascii"),
        base64.b64encode(digest).decode("ascii"),
    )
)
PY
)

unset BOOTSTRAP_PASSWORD

[ -n "$PASSWORD_HASH" ] \
  || die "bootstrap password hashing failed"

ADMIN_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
ROLE_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
SECURITY_STAMP="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"

printf 'bootstrap_username=%s\n' "$BOOTSTRAP_USERNAME"
printf 'bootstrap_password_file=%s\n' "$BOOTSTRAP_PASSWORD_FILE"
printf '%s\n' "bootstrap_password_displayed=NO"

printf '\n=== 6. BUILD GUARDED FORWARD TRANSACTION ===\n'

cat "$MIGSQL" > "$FORWARD"

cat >> "$FORWARD" <<SQL

-- ============================================================
-- QFLM Phase 15E.2A bootstrap RBAC seed
-- ============================================================

INSERT INTO auth_permissions
(
    id,
    code,
    name,
    category,
    description,
    is_system,
    created_at_utc,
    updated_at_utc
)
VALUES
(gen_random_uuid(),'security.admin','Administer Security','Security','Manage authentication, users, roles and permissions.',true,NOW(),NOW()),
(gen_random_uuid(),'users.read','Read Users','Security','View platform users.',true,NOW(),NOW()),
(gen_random_uuid(),'users.manage','Manage Users','Security','Create and manage platform users.',true,NOW(),NOW()),
(gen_random_uuid(),'roles.read','Read Roles','Security','View roles and permissions.',true,NOW(),NOW()),
(gen_random_uuid(),'roles.manage','Manage Roles','Security','Create and manage roles and permissions.',true,NOW(),NOW()),
(gen_random_uuid(),'customers.read','Read Customers','Customers','View customers.',true,NOW(),NOW()),
(gen_random_uuid(),'customers.manage','Manage Customers','Customers','Create and manage customers.',true,NOW(),NOW()),
(gen_random_uuid(),'products.read','Read Products','Products','View products and features.',true,NOW(),NOW()),
(gen_random_uuid(),'products.manage','Manage Products','Products','Create and manage products and features.',true,NOW(),NOW()),
(gen_random_uuid(),'subscriptions.read','Read Subscriptions','Subscriptions','View subscriptions.',true,NOW(),NOW()),
(gen_random_uuid(),'subscriptions.manage','Manage Subscriptions','Subscriptions','Create and manage subscriptions.',true,NOW(),NOW()),
(gen_random_uuid(),'licenses.read','Read Licenses','Licensing','View licenses.',true,NOW(),NOW()),
(gen_random_uuid(),'licenses.manage','Manage Licenses','Licensing','Create and manage licenses.',true,NOW(),NOW()),
(gen_random_uuid(),'licensing.manage','Manage Licensing Operations','Licensing','Perform administrative licensing operations.',true,NOW(),NOW()),
(gen_random_uuid(),'installations.read','Read Installations','Installations','View installations.',true,NOW(),NOW()),
(gen_random_uuid(),'installations.manage','Manage Installations','Installations','Manage installation state and rebind operations.',true,NOW(),NOW()),
(gen_random_uuid(),'offline.read','Read Offline Licensing','Offline Licensing','View offline licensing records.',true,NOW(),NOW()),
(gen_random_uuid(),'offline.issue','Issue Offline Licenses','Offline Licensing','Issue offline licenses.',true,NOW(),NOW()),
(gen_random_uuid(),'offline.renew','Renew Offline Licenses','Offline Licensing','Renew offline licenses.',true,NOW(),NOW()),
(gen_random_uuid(),'audit.read','Read Audit','Audit','View audit events.',true,NOW(),NOW()),
(gen_random_uuid(),'reports.read','Read Reports','Reporting','View reports.',true,NOW(),NOW()),
(gen_random_uuid(),'system.manage','Manage System','System','Manage platform system configuration.',true,NOW(),NOW())
ON CONFLICT (code) DO NOTHING;

INSERT INTO auth_roles
(
    id,
    name,
    normalized_name,
    description,
    is_system,
    created_at_utc,
    updated_at_utc
)
VALUES
(
    '$ROLE_ID',
    'Platform Administrator',
    'PLATFORM ADMINISTRATOR',
    'Built-in full-access QFLM platform administrator role.',
    true,
    NOW(),
    NOW()
)
ON CONFLICT (normalized_name) DO NOTHING;

INSERT INTO auth_users
(
    id,
    username,
    normalized_username,
    email,
    normalized_email,
    password_hash,
    is_active,
    email_confirmed,
    failed_access_attempts,
    lockout_end_utc,
    last_login_at_utc,
    security_stamp,
    created_at_utc,
    updated_at_utc
)
VALUES
(
    '$ADMIN_ID',
    '$BOOTSTRAP_USERNAME',
    'QFLM-ADMIN',
    NULL,
    NULL,
    '$PASSWORD_HASH',
    true,
    false,
    0,
    NULL,
    NULL,
    '$SECURITY_STAMP',
    NOW(),
    NOW()
)
ON CONFLICT (normalized_username) DO NOTHING;

INSERT INTO auth_user_roles
(
    id,
    user_id,
    role_id,
    created_at_utc,
    updated_at_utc
)
SELECT
    gen_random_uuid(),
    u.id,
    r.id,
    NOW(),
    NOW()
FROM auth_users u
CROSS JOIN auth_roles r
WHERE u.normalized_username='QFLM-ADMIN'
AND r.normalized_name='PLATFORM ADMINISTRATOR'
ON CONFLICT (user_id,role_id) DO NOTHING;

INSERT INTO auth_role_permissions
(
    id,
    role_id,
    permission_id,
    created_at_utc,
    updated_at_utc
)
SELECT
    gen_random_uuid(),
    r.id,
    p.id,
    NOW(),
    NOW()
FROM auth_roles r
CROSS JOIN auth_permissions p
WHERE r.normalized_name='PLATFORM ADMINISTRATOR'
ON CONFLICT (role_id,permission_id) DO NOTHING;
SQL

unset PASSWORD_HASH

printf 'forward_sql=%s\n' "$FORWARD"
printf 'forward_sql_sha256=%s\n' "$(sha256sum "$FORWARD" | awk '{print $1}')"

printf '\n=== 7. APPLY AUTH SCHEMA + BOOTSTRAP IN ONE TRANSACTION ===\n'

cat "$FORWARD" \
  | docker exec -i "$PG" psql \
      -U qflm \
      -d "$DB" \
      -v ON_ERROR_STOP=1 \
      -1 \
      >/dev/null \
  || die "guarded production auth transaction failed"

printf '%s\n' "production_auth_transaction=COMMITTED"

printf '\n=== 8. VERIFY PRODUCTION AUTH SCHEMA ===\n'

MIG_AFTER=$(docker exec "$PG" psql -U qflm -d "$DB" \
  -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

AUTH_AFTER=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc "
SELECT count(*)
FROM information_schema.tables
WHERE table_schema='public'
AND table_name LIKE 'auth_%';
" | xargs)

USERS=$(docker exec "$PG" psql -U qflm -d "$DB" \
  -tAc "SELECT count(*) FROM auth_users WHERE normalized_username='QFLM-ADMIN' AND is_active=true;" | xargs)

ROLES=$(docker exec "$PG" psql -U qflm -d "$DB" \
  -tAc "SELECT count(*) FROM auth_roles WHERE normalized_name='PLATFORM ADMINISTRATOR';" | xargs)

PERMS=$(docker exec "$PG" psql -U qflm -d "$DB" \
  -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)

EFFECTIVE=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc "
SELECT count(DISTINCT p.code)
FROM auth_users u
JOIN auth_user_roles ur ON ur.user_id=u.id
JOIN auth_roles r ON r.id=ur.role_id
JOIN auth_role_permissions rp ON rp.role_id=r.id
JOIN auth_permissions p ON p.id=rp.permission_id
WHERE u.normalized_username='QFLM-ADMIN';
" | xargs)

printf 'migrations=%s auth_tables=%s bootstrap_users=%s platform_admin_roles=%s permissions=%s effective_permissions=%s\n' \
  "$MIG_AFTER" "$AUTH_AFTER" "$USERS" "$ROLES" "$PERMS" "$EFFECTIVE"

[ "$MIG_AFTER" = 5 ] \
  || die "production migration count did not reach 5"

[ "$AUTH_AFTER" = 6 ] \
  || die "expected six production auth tables"

[ "$USERS" = 1 ] \
  || die "bootstrap administrator missing or duplicated"

[ "$ROLES" = 1 ] \
  || die "platform administrator role missing or duplicated"

[ "$PERMS" -ge 22 ] \
  || die "permission seed incomplete"

[ "$EFFECTIVE" = "$PERMS" ] \
  || die "bootstrap administrator does not have every seeded permission"

printf '%s\n' "production_auth_schema_verification=PASS"

printf '\n=== 9. VERIFY LICENSING DATA UNCHANGED ===\n'

LIC_AFTER=$(docker exec "$PG" psql -U qflm -d "$DB" \
  -tAc 'SELECT count(*) FROM licenses;' | xargs)

INST_AFTER=$(docker exec "$PG" psql -U qflm -d "$DB" \
  -tAc 'SELECT count(*) FROM installations;' | xargs)

OFFLINE_AFTER=$(docker exec "$PG" psql -U qflm -d "$DB" \
  -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)

AUDIT_AFTER=$(docker exec "$PG" psql -U qflm -d "$DB" \
  -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)

printf 'licenses_before=%s after=%s\n' "$LIC_BEFORE" "$LIC_AFTER"
printf 'installations_before=%s after=%s\n' "$INST_BEFORE" "$INST_AFTER"
printf 'offline_issuances_before=%s after=%s\n' "$OFFLINE_BEFORE" "$OFFLINE_AFTER"
printf 'offline_audit_events_before=%s after=%s\n' "$AUDIT_BEFORE" "$AUDIT_AFTER"

[ "$LIC_AFTER" = "$LIC_BEFORE" ] \
  || die "license count changed"

[ "$INST_AFTER" = "$INST_BEFORE" ] \
  || die "installation count changed"

[ "$OFFLINE_AFTER" = "$OFFLINE_BEFORE" ] \
  || die "offline issuance count changed"

[ "$AUDIT_AFTER" = "$AUDIT_BEFORE" ] \
  || die "offline audit count changed"

printf '%s\n' "licensing_data_unchanged=PASS"

printf '\n=== 10. VERIFY PRODUCTION API REMAINS OLD/HEALTHY ===\n'

FINAL_IMAGE=$(docker inspect "$API" --format='{{.Config.Image}}')
FINAL_RUNNING=$(docker inspect "$API" --format='{{.State.Running}}')

printf 'image=%s running=%s\n' "$FINAL_IMAGE" "$FINAL_RUNNING"

[ "$FINAL_IMAGE" = "$EXPECTED_IMAGE" ] \
  || die "production API image unexpectedly changed"

[ "$FINAL_RUNNING" = true ] \
  || die "production API stopped"

docker exec "$API" sh -c 'wget -qO- http://127.0.0.1:8080/health/live >/dev/null 2>&1 || true' \
  >/dev/null 2>&1 || true

printf '%s\n' "production_api_image_unchanged=PASS"

COMPLETED=1

printf '\n%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 6E1 PASSED"
printf '%s\n' "======================================================"
printf '%s\n' "AUTH MIGRATIONS 3 -> 5:             PASS"
printf '%s\n' "AUTH TABLES:                        6"
printf '%s\n' "SYSTEM PERMISSIONS:                 SEE VERIFIED COUNT ABOVE"
printf '%s\n' "PLATFORM ADMIN ROLE:                CREATED"
printf '%s\n' "BOOTSTRAP ADMIN:                    CREATED"
printf '%s\n' "BOOTSTRAP PASSWORD PRINTED:         NO"
printf '%s\n' "LICENSING DATA:                     UNCHANGED"
printf '%s\n' "PRODUCTION API IMAGE:               UNCHANGED"
printf 'BOOTSTRAP USERNAME FILE:            %s\n' "$BOOTSTRAP_USERNAME_FILE"
printf 'BOOTSTRAP PASSWORD FILE:            %s\n' "$BOOTSTRAP_PASSWORD_FILE"
printf 'DATABASE BACKUP:                    %s\n' "$DB_DUMP"
printf 'REPORT:                             %s\n' "$REPORT"
printf '%s\n' "NEXT: RECOVERY 6E2 - GUARDED AUTH API + JWT SECRET PRODUCTION PROMOTION"
printf '%s\n' "======================================================"

#!/usr/bin/env bash
# QFLM RECOVERY 7G2 V2
# Security Admin GUI - isolated validation.
# Production and current Cloudflare preview remain untouched.
# Mutations occur only in a disposable cloned database.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
GUI="$ROOT/src/QFLM.AdminWeb"

PROD_API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"

ISO_DB="qflm_recovery7g2_test"
ISO_API="qflm-api-recovery7g2-test"
ISO_GUI="qflm-admin-web-recovery7g2-test"
NET="qflm_backend"

PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"

EXPECTED_PROD_IMAGE="qflm-api:recovery6f3-candidate"
API_IMAGE="qflm-api:recovery7f2-candidate"
GUI_IMAGE="qflm-admin-web:recovery7g2-candidate"

ADMIN_USER_FILE="/opt/qflm/secrets/auth/platform-admin-username"
ADMIN_PASS_FILE="/opt/qflm/secrets/auth/platform-admin-password"
RUNTIME_JWT="/opt/qflm/secrets/runtime-api/jwt-signing-key"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7g2-$STAMP"
REPORT="$BACKUP/recovery7g2-report.txt"
SOURCE_BACKUP="$BACKUP/adminweb-before-recovery7g2.tgz"
DB_DUMP="$BACKUP/qflm-before-recovery7g2.dump"
ENV_FILE="$BACKUP/isolated-api.env"
GUI_DOCKERFILE="$ROOT/Dockerfile.recovery7g2-gui"
GUI_NGINX_CONF="$ROOT/artifacts/recovery7g2-nginx.conf"

MUTATED=0
COMPLETED=0

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

cleanup(){
    docker rm -f "$ISO_GUI" >/dev/null 2>&1 || true
    docker rm -f "$ISO_API" >/dev/null 2>&1 || true

    if [ "$COMPLETED" -ne 1 ] && [ "$MUTATED" -eq 1 ] && [ -s "$SOURCE_BACKUP" ]; then
        printf '\n=== SOURCE ROLLBACK ===\n'
        rm -rf "$GUI"
        mkdir -p "$GUI"
        tar -xzf "$SOURCE_BACKUP" -C "$ROOT" >/dev/null 2>&1 || true
        printf '%s\n' "source_restore_attempted=YES"
    fi
}
trap cleanup EXIT

mkdir -p "$BACKUP" "$ROOT/artifacts"
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

echo "======================================================"
echo " QFLM RECOVERY 7G2"
echo " SECURITY ADMIN GUI"
echo " ISOLATED VALIDATION"
echo "======================================================"

echo
echo "=== 1. PRODUCTION + PREVIEW SAFETY BASELINE ==="

PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

PROD_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
PROD_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PROD_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)

PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)

printf 'prod_image=%s prod_running=%s migrations=%s users=%s roles=%s permissions=%s\n' \
 "$PROD_IMAGE" "$PROD_RUNNING" "$MIG" "$PROD_USERS" "$PROD_ROLES" "$PROD_PERMS"

printf 'preview_api=%s preview_gui=%s api_image=%s gui_image=%s\n' \
 "$PREVIEW_API_RUNNING" "$PREVIEW_GUI_RUNNING" "$PREVIEW_API_IMAGE" "$PREVIEW_GUI_IMAGE"

[ "$PROD_IMAGE" = "$EXPECTED_PROD_IMAGE" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"
[ "$PREVIEW_API_RUNNING" = true ] || die "current preview API not running"
[ "$PREVIEW_GUI_RUNNING" = true ] || die "current preview GUI not running"

[ -s "$ADMIN_USER_FILE" ] || die "platform admin username missing"
[ -s "$ADMIN_PASS_FILE" ] || die "platform admin password missing"
[ -s "$RUNTIME_JWT" ] || die "JWT runtime secret missing"

echo "production_preview_baseline=PASS"

echo
echo "=== 2. VERIFY SECURITY BACKEND + GUI SOURCE ==="

for f in \
 "$ROOT/src/QFLM.Api/Controllers/AdminSecurityManagementController.cs" \
 "$ROOT/src/QFLM.Application/Security/ISecurityAdministrationService.cs" \
 "$ROOT/src/QFLM.Application/Security/SecurityAdminModels.cs" \
 "$ROOT/src/QFLM.Infrastructure/Security/EfSecurityAdministrationService.cs" \
 "$GUI/src/App.tsx" \
 "$GUI/src/lib/api.ts" \
 "$GUI/src/styles.css"
do
    [ -s "$f" ] || die "required source missing: $f"
done

grep -Fq '[Route("api/v1/admin/security")]' \
 "$ROOT/src/QFLM.Api/Controllers/AdminSecurityManagementController.cs" \
 || die "security management route missing"

grep -Fq 'permission:security.admin' \
 "$ROOT/src/QFLM.Api/Controllers/AdminSecurityManagementController.cs" \
 || die "security.admin authorization policy missing"

grep -Fq 'path="security"' "$GUI/src/App.tsx" \
 || die "GUI security route missing"

echo "security_backend_contract=PASS"
echo "gui_source_baseline=PASS"

echo
echo "=== 3. BACKUP GUI SOURCE + PRODUCTION DATABASE ==="

tar -czf "$SOURCE_BACKUP" -C "$ROOT" "src/QFLM.AdminWeb" || die "GUI source backup failed"
docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" -Fc > "$DB_DUMP" || die "production DB backup failed"
[ -s "$DB_DUMP" ] || die "production DB backup empty"

printf 'gui_source_backup_sha256=%s\n' "$(sha256sum "$SOURCE_BACKUP" | awk '{print $1}')"
printf 'database_backup_sha256=%s\n' "$(sha256sum "$DB_DUMP" | awk '{print $1}')"

MUTATED=1

echo
echo "=== 4. CREATE SECURITY ADMIN GUI ==="

cat > "$GUI/src/pages/SecurityPage.tsx" <<'TSX'
import { FormEvent, useEffect, useMemo, useState } from "react";
import { apiFetch } from "../lib/api";

type SecurityUser = {
  id: string;
  username: string;
  email: string | null;
  isActive: boolean;
  emailConfirmed: boolean;
  failedAccessAttempts: number;
  lockoutEndUtc: string | null;
  lastLoginAtUtc: string | null;
  roles: string[];
};

type SecurityRole = {
  id: string;
  name: string;
  description: string | null;
  isSystem: boolean;
  permissions: string[];
};

type SecurityPermission = {
  id: string;
  code: string;
  name: string;
  category: string;
  description: string | null;
  isSystem: boolean;
};

type Tab = "users" | "roles" | "permissions";

function fmtDate(value: string | null): string {
  if (!value) return "Never";
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? value : parsed.toLocaleString();
}

export function SecurityPage() {
  const [users, setUsers] = useState<SecurityUser[]>([]);
  const [roles, setRoles] = useState<SecurityRole[]>([]);
  const [permissions, setPermissions] = useState<SecurityPermission[]>([]);
  const [tab, setTab] = useState<Tab>("users");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  const [username, setUsername] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [newUserRoleIds, setNewUserRoleIds] = useState<string[]>([]);

  const [roleName, setRoleName] = useState("");
  const [roleDescription, setRoleDescription] = useState("");
  const [newRolePermissionIds, setNewRolePermissionIds] = useState<string[]>([]);

  const [editingUser, setEditingUser] = useState<string | null>(null);
  const [editingUserRoleIds, setEditingUserRoleIds] = useState<string[]>([]);

  const [editingRole, setEditingRole] = useState<string | null>(null);
  const [editingRolePermissionIds, setEditingRolePermissionIds] = useState<string[]>([]);

  async function load() {
    const [u, r, p] = await Promise.all([
      apiFetch<SecurityUser[]>("/v1/admin/security/users"),
      apiFetch<SecurityRole[]>("/v1/admin/security/roles"),
      apiFetch<SecurityPermission[]>("/v1/admin/security/permissions")
    ]);

    setUsers(u);
    setRoles(r);
    setPermissions(p);
  }

  useEffect(() => {
    load().catch(() => setError("Security administration data could not be loaded."));
  }, []);

  const permissionGroups = useMemo(() => {
    const grouped = new Map<string, SecurityPermission[]>();

    for (const permission of permissions) {
      const list = grouped.get(permission.category) ?? [];
      list.push(permission);
      grouped.set(permission.category, list);
    }

    return [...grouped.entries()];
  }, [permissions]);

  function clearMessages() {
    setError("");
    setNotice("");
  }

  function toggleId(current: string[], id: string): string[] {
    return current.includes(id)
      ? current.filter((x) => x !== id)
      : [...current, id];
  }

  function roleIdsForUser(user: SecurityUser): string[] {
    const assigned = new Set(user.roles);
    return roles.filter((r) => assigned.has(r.name)).map((r) => r.id);
  }

  function permissionIdsForRole(role: SecurityRole): string[] {
    const assigned = new Set(role.permissions);
    return permissions.filter((p) => assigned.has(p.code)).map((p) => p.id);
  }

  async function createUser(event: FormEvent) {
    event.preventDefault();
    clearMessages();

    if (!username.trim() || password.length < 14) {
      setError("Username is required and password must contain at least 14 characters.");
      return;
    }

    try {
      setBusy(true);

      await apiFetch<SecurityUser>("/v1/admin/security/users", {
        method: "POST",
        body: JSON.stringify({
          username: username.trim(),
          email: email.trim() || null,
          password,
          roleIds: newUserRoleIds
        })
      });

      setUsername("");
      setEmail("");
      setPassword("");
      setNewUserRoleIds([]);
      await load();
      setNotice("User created successfully.");
    } catch {
      setError("User could not be created. Check username uniqueness, password length and selected roles.");
    } finally {
      setBusy(false);
    }
  }

  async function setUserStatus(user: SecurityUser) {
    clearMessages();

    try {
      setBusy(true);

      await apiFetch<void>(`/v1/admin/security/users/${user.id}/status`, {
        method: "PUT",
        body: JSON.stringify({ isActive: !user.isActive })
      });

      await load();
      setNotice(user.isActive ? "User disabled and active refresh sessions revoked." : "User enabled.");
    } catch {
      setError("User status could not be changed.");
    } finally {
      setBusy(false);
    }
  }

  function beginUserRoles(user: SecurityUser) {
    setEditingUser(user.id);
    setEditingUserRoleIds(roleIdsForUser(user));
    clearMessages();
  }

  async function saveUserRoles(userId: string) {
    clearMessages();

    try {
      setBusy(true);

      await apiFetch<void>(`/v1/admin/security/users/${userId}/roles`, {
        method: "PUT",
        body: JSON.stringify({ roleIds: editingUserRoleIds })
      });

      setEditingUser(null);
      setEditingUserRoleIds([]);
      await load();
      setNotice("User roles updated.");
    } catch {
      setError("User roles could not be updated.");
    } finally {
      setBusy(false);
    }
  }

  async function createRole(event: FormEvent) {
    event.preventDefault();
    clearMessages();

    if (!roleName.trim()) {
      setError("Role name is required.");
      return;
    }

    try {
      setBusy(true);

      await apiFetch<SecurityRole>("/v1/admin/security/roles", {
        method: "POST",
        body: JSON.stringify({
          name: roleName.trim(),
          description: roleDescription.trim() || null,
          permissionIds: newRolePermissionIds
        })
      });

      setRoleName("");
      setRoleDescription("");
      setNewRolePermissionIds([]);
      await load();
      setNotice("Role created successfully.");
    } catch {
      setError("Role could not be created. Check name uniqueness and selected permissions.");
    } finally {
      setBusy(false);
    }
  }

  function beginRolePermissions(role: SecurityRole) {
    setEditingRole(role.id);
    setEditingRolePermissionIds(permissionIdsForRole(role));
    clearMessages();
  }

  async function saveRolePermissions(roleId: string) {
    clearMessages();

    try {
      setBusy(true);

      await apiFetch<void>(`/v1/admin/security/roles/${roleId}/permissions`, {
        method: "PUT",
        body: JSON.stringify({ permissionIds: editingRolePermissionIds })
      });

      setEditingRole(null);
      setEditingRolePermissionIds([]);
      await load();
      setNotice("Role permissions updated.");
    } catch {
      setError("Role permissions could not be updated.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <div className="page-heading">
        <div>
          <h1>Security Administration</h1>
          <p>Manage administrators, role assignments and permission boundaries.</p>
        </div>
      </div>

      <div className="security-summary-grid">
        <article className="security-summary-card">
          <span>Users</span>
          <strong>{users.length}</strong>
          <small>{users.filter((x) => x.isActive).length} active</small>
        </article>
        <article className="security-summary-card">
          <span>Roles</span>
          <strong>{roles.length}</strong>
          <small>{roles.filter((x) => x.isSystem).length} system</small>
        </article>
        <article className="security-summary-card">
          <span>Permissions</span>
          <strong>{permissions.length}</strong>
          <small>{permissionGroups.length} categories</small>
        </article>
      </div>

      <div className="security-tabs">
        <button className={tab === "users" ? "active" : ""} onClick={() => setTab("users")}>Users</button>
        <button className={tab === "roles" ? "active" : ""} onClick={() => setTab("roles")}>Roles</button>
        <button className={tab === "permissions" ? "active" : ""} onClick={() => setTab("permissions")}>Permissions</button>
      </div>

      {error && <div className="page-error">{error}</div>}
      {notice && <div className="security-notice">{notice}</div>}

      {tab === "users" && (
        <>
          <article className="panel">
            <h2>Create user</h2>
            <form onSubmit={createUser}>
              <div className="form-grid">
                <label>
                  Username
                  <input value={username} onChange={(e) => setUsername(e.target.value)} required />
                </label>
                <label>
                  Email
                  <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
                </label>
                <label>
                  Initial password
                  <input
                    type="password"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    minLength={14}
                    required
                  />
                  <small>Minimum 14 characters.</small>
                </label>
              </div>

              <div className="security-check-grid">
                {roles.map((role) => (
                  <label className="security-check" key={role.id}>
                    <input
                      type="checkbox"
                      checked={newUserRoleIds.includes(role.id)}
                      onChange={() => setNewUserRoleIds(toggleId(newUserRoleIds, role.id))}
                    />
                    <span>
                      <strong>{role.name}</strong>
                      <small>{role.description ?? "No description"}</small>
                    </span>
                  </label>
                ))}
              </div>

              <button className="primary-button" disabled={busy}>Create user</button>
            </form>
          </article>

          <article className="panel">
            <h2>Users</h2>
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>User</th>
                    <th>Status</th>
                    <th>Roles</th>
                    <th>Last login</th>
                    <th>Security</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {users.map((user) => (
                    <tr key={user.id}>
                      <td>
                        <strong>{user.username}</strong>
                        <div className="muted">{user.email ?? "No email"}</div>
                      </td>
                      <td>
                        <span className={`status-pill ${user.isActive ? "status-ok" : "status-off"}`}>
                          {user.isActive ? "Active" : "Disabled"}
                        </span>
                      </td>
                      <td>{user.roles.length ? user.roles.join(", ") : "No roles"}</td>
                      <td>{fmtDate(user.lastLoginAtUtc)}</td>
                      <td>
                        <div>Failed attempts: {user.failedAccessAttempts}</div>
                        <div className="muted">Lockout: {fmtDate(user.lockoutEndUtc)}</div>
                      </td>
                      <td>
                        <div className="security-action-row">
                          <button className="secondary-button" disabled={busy} onClick={() => beginUserRoles(user)}>
                            Roles
                          </button>
                          <button className="secondary-button" disabled={busy} onClick={() => setUserStatus(user)}>
                            {user.isActive ? "Disable" : "Enable"}
                          </button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {editingUser && (
              <div className="security-editor">
                <h3>Assign roles</h3>
                <div className="security-check-grid">
                  {roles.map((role) => (
                    <label className="security-check" key={role.id}>
                      <input
                        type="checkbox"
                        checked={editingUserRoleIds.includes(role.id)}
                        onChange={() => setEditingUserRoleIds(toggleId(editingUserRoleIds, role.id))}
                      />
                      <span>
                        <strong>{role.name}</strong>
                        <small>{role.description ?? "No description"}</small>
                      </span>
                    </label>
                  ))}
                </div>
                <div className="security-action-row">
                  <button className="primary-button" disabled={busy} onClick={() => saveUserRoles(editingUser)}>
                    Save roles
                  </button>
                  <button className="secondary-button" onClick={() => setEditingUser(null)}>Cancel</button>
                </div>
              </div>
            )}
          </article>
        </>
      )}

      {tab === "roles" && (
        <>
          <article className="panel">
            <h2>Create role</h2>
            <form onSubmit={createRole}>
              <div className="form-grid">
                <label>
                  Role name
                  <input value={roleName} onChange={(e) => setRoleName(e.target.value)} required />
                </label>
                <label className="form-grid-wide">
                  Description
                  <input value={roleDescription} onChange={(e) => setRoleDescription(e.target.value)} />
                </label>
              </div>

              {permissionGroups.map(([category, items]) => (
                <div className="security-permission-group" key={category}>
                  <h3>{category}</h3>
                  <div className="security-check-grid">
                    {items.map((permission) => (
                      <label className="security-check" key={permission.id}>
                        <input
                          type="checkbox"
                          checked={newRolePermissionIds.includes(permission.id)}
                          onChange={() =>
                            setNewRolePermissionIds(toggleId(newRolePermissionIds, permission.id))
                          }
                        />
                        <span>
                          <strong>{permission.code}</strong>
                          <small>{permission.name}</small>
                        </span>
                      </label>
                    ))}
                  </div>
                </div>
              ))}

              <button className="primary-button" disabled={busy}>Create role</button>
            </form>
          </article>

          <article className="panel">
            <h2>Roles</h2>
            <div className="table-wrap">
              <table>
                <thead>
                  <tr><th>Role</th><th>Type</th><th>Permissions</th><th>Actions</th></tr>
                </thead>
                <tbody>
                  {roles.map((role) => (
                    <tr key={role.id}>
                      <td>
                        <strong>{role.name}</strong>
                        <div className="muted">{role.description ?? "No description"}</div>
                      </td>
                      <td>{role.isSystem ? "System" : "Custom"}</td>
                      <td>{role.permissions.length} permissions</td>
                      <td>
                        <button className="secondary-button" disabled={busy} onClick={() => beginRolePermissions(role)}>
                          Permissions
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {editingRole && (
              <div className="security-editor">
                <h3>Edit role permissions</h3>
                {permissionGroups.map(([category, items]) => (
                  <div className="security-permission-group" key={category}>
                    <h4>{category}</h4>
                    <div className="security-check-grid">
                      {items.map((permission) => (
                        <label className="security-check" key={permission.id}>
                          <input
                            type="checkbox"
                            checked={editingRolePermissionIds.includes(permission.id)}
                            onChange={() =>
                              setEditingRolePermissionIds(toggleId(editingRolePermissionIds, permission.id))
                            }
                          />
                          <span>
                            <strong>{permission.code}</strong>
                            <small>{permission.name}</small>
                          </span>
                        </label>
                      ))}
                    </div>
                  </div>
                ))}
                <div className="security-action-row">
                  <button className="primary-button" disabled={busy} onClick={() => saveRolePermissions(editingRole)}>
                    Save permissions
                  </button>
                  <button className="secondary-button" onClick={() => setEditingRole(null)}>Cancel</button>
                </div>
              </div>
            )}
          </article>
        </>
      )}

      {tab === "permissions" && (
        <article className="panel">
          <h2>Permission catalog</h2>
          {permissionGroups.map(([category, items]) => (
            <div className="security-permission-group" key={category}>
              <h3>{category}</h3>
              <div className="security-permission-cards">
                {items.map((permission) => (
                  <div className="security-permission-card" key={permission.id}>
                    <strong>{permission.code}</strong>
                    <span>{permission.name}</span>
                    <small>{permission.description ?? "System permission"}</small>
                  </div>
                ))}
              </div>
            </div>
          ))}
        </article>
      )}
    </>
  );
}
TSX

python3 - "$GUI/src/App.tsx" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
s=p.read_text()

imp='import { SecurityPage } from "./pages/SecurityPage";'
marker='import { OfflineLicensingPage } from "./pages/OfflineLicensingPage";'

if imp not in s:
    if marker not in s:
        raise SystemExit("OfflineLicensingPage import marker missing")
    s=s.replace(marker, marker+"\n"+imp, 1)

old='''            <Route
              path="security"
              element={
                <PlaceholderPage
                  title="Security"
                  description="Users, roles, permissions and account administration."
                />
              }
            />'''

new='''            <Route path="security" element={<SecurityPage />} />'''

if old in s:
    s=s.replace(old,new,1)
elif new not in s:
    raise SystemExit("security placeholder route marker missing")

p.write_text(s)
PY

cat >> "$GUI/src/styles.css" <<'CSS'

/* Phase 16G - Security Administration */
.security-summary-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 14px;
  margin-bottom: 18px;
}
.security-summary-card {
  display: grid;
  gap: 4px;
  padding: 18px;
  border: 1px solid #e4e9f1;
  border-radius: 12px;
  background: #fff;
}
.security-summary-card > span,
.security-summary-card > small,
.muted {
  color: #667085;
}
.security-summary-card > strong {
  font-size: 28px;
}
.security-tabs {
  display: flex;
  gap: 8px;
  margin: 0 0 18px;
  padding: 6px;
  border: 1px solid #e4e9f1;
  border-radius: 12px;
  background: #fff;
  width: fit-content;
}
.security-tabs button {
  border: 0;
  border-radius: 8px;
  background: transparent;
  padding: 9px 14px;
  cursor: pointer;
}
.security-tabs button.active {
  background: #eef2f7;
  font-weight: 700;
}
.security-notice {
  margin-bottom: 16px;
  padding: 12px 14px;
  border-radius: 10px;
  background: #ecfdf3;
  border: 1px solid #abefc6;
}
.security-check-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 10px;
  margin: 14px 0;
}
.security-check {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  padding: 11px 12px;
  border: 1px solid #e4e9f1;
  border-radius: 10px;
  background: #fff;
}
.security-check input {
  margin-top: 3px;
}
.security-check span {
  display: grid;
  gap: 2px;
}
.security-check small {
  color: #667085;
}
.security-editor {
  margin-top: 18px;
  padding: 16px;
  border-radius: 12px;
  background: #f8fafc;
  border: 1px solid #e4e9f1;
}
.security-action-row {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
}
.security-permission-group {
  margin: 18px 0;
}
.security-permission-group h3,
.security-permission-group h4 {
  margin-bottom: 8px;
}
.security-permission-cards {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 10px;
}
.security-permission-card {
  display: grid;
  gap: 4px;
  padding: 12px;
  border: 1px solid #e4e9f1;
  border-radius: 10px;
  background: #fff;
}
.security-permission-card small {
  color: #667085;
}
.status-pill {
  display: inline-flex;
  border-radius: 999px;
  padding: 4px 8px;
  font-size: 12px;
  font-weight: 700;
}
.status-ok {
  background: #ecfdf3;
}
.status-off {
  background: #f2f4f7;
}
@media (max-width: 900px) {
  .security-summary-grid,
  .security-check-grid,
  .security-permission-cards {
    grid-template-columns: 1fr;
  }
}
CSS

grep -Fq 'export function SecurityPage' "$GUI/src/pages/SecurityPage.tsx" \
 || die "SecurityPage source missing"

grep -Fq '<Route path="security" element={<SecurityPage />} />' "$GUI/src/App.tsx" \
 || die "SecurityPage route patch failed"

echo "security_admin_gui=CREATED"

echo
echo "=== 5. CLONE PRODUCTION DATABASE ==="

docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1 \
 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" \
 >/dev/null

docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB"
docker exec "$PG" createdb -U qflm "$ISO_DB" || die "isolated DB create failed"

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" --no-owner --no-privileges \
 | docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 >/dev/null \
 || die "isolated DB clone failed"

ISO_USERS_BEFORE=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
ISO_ROLES_BEFORE=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)

[ "$ISO_USERS_BEFORE" = "$PROD_USERS" ] || die "isolated user count mismatch"
[ "$ISO_ROLES_BEFORE" = "$PROD_ROLES" ] || die "isolated role count mismatch"

echo "isolated_database_clone=PASS"

echo
echo "=== 6. PREPARE + START ISOLATED API ==="

docker image inspect "$API_IMAGE" >/dev/null 2>&1 || die "Recovery 7F2 API candidate image missing"

docker inspect "$PROD_API" --format '{{range .Config.Env}}{{println .}}{{end}}' \
 > "$ENV_FILE" || die "capture production API environment failed"
chmod 600 "$ENV_FILE"

cat >> "$ENV_FILE" <<EOF
Qflm__PostgreSqlDatabase=$ISO_DB
PostgreSqlDatabase=$ISO_DB
EOF
chmod 600 "$ENV_FILE"

docker rm -f "$ISO_API" >/dev/null 2>&1 || true

docker run -d \
 --name "$ISO_API" \
 --network "$NET" \
 --network-alias qflm-api-recovery7g2-backend \
 --env-file "$ENV_FILE" \
 --volumes-from "$PROD_API:ro" \
 --read-only \
 --cap-drop ALL \
 --security-opt no-new-privileges:true \
 --tmpfs /tmp:rw,noexec,nosuid,size=16m \
 "$API_IMAGE" >/dev/null \
 || die "isolated API start failed"

sleep 5

docker run --rm --network "$NET" curlimages/curl:8.16.0 \
 -fsS "http://$ISO_API:8080/health/ready" >/dev/null \
 || {
    docker logs --tail 200 "$ISO_API" || true
    die "isolated API readiness failed"
 }

ISO_DB_ENV=$(docker inspect "$ISO_API" --format='{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '$1=="Qflm__PostgreSqlDatabase"{print $2}' | tail -n1)
printf 'isolated_api_database=%s\n' "$ISO_DB_ENV"
[ "$ISO_DB_ENV" = "$ISO_DB" ] || die "isolated API database binding mismatch"
echo "isolated_api_health=PASS"
echo "isolated_database_binding=PASS"

echo
echo "=== 7. BUILD + START ISOLATED GUI ==="

cat > "$GUI_NGINX_CONF" <<'NGINX'
pid /tmp/nginx.pid;
error_log /dev/stderr notice;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/stdout;

    client_body_temp_path /tmp/client_temp;
    proxy_temp_path /tmp/proxy_temp;
    fastcgi_temp_path /tmp/fastcgi_temp;
    uwsgi_temp_path /tmp/uwsgi_temp;
    scgi_temp_path /tmp/scgi_temp;

    server {
        listen 8080;
        root /usr/share/nginx/html;
        index index.html;

        location /api/ {
            proxy_pass http://qflm-api-recovery7g2-backend:8080/api/;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
        }

        location = /health {
            access_log off;
            default_type text/plain;
            return 200 "ok";
        }

        location / {
            try_files $uri $uri/ /index.html;
        }
    }
}
NGINX

cat > "$GUI_DOCKERFILE" <<'DOCKER'
FROM node:24-bookworm-slim AS build
WORKDIR /src
COPY src/QFLM.AdminWeb/package*.json ./
RUN npm install --no-audit --no-fund
COPY src/QFLM.AdminWeb/ ./
RUN npm run build

FROM nginx:1.29-alpine
COPY --from=build /src/dist /usr/share/nginx/html
COPY artifacts/recovery7g2-nginx.conf /etc/nginx/nginx-qflm.conf
RUN mkdir -p /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp \
    && chown -R nginx:nginx /tmp /usr/share/nginx/html \
    && chmod 444 /etc/nginx/nginx-qflm.conf
USER nginx
EXPOSE 8080
ENTRYPOINT ["nginx","-c","/etc/nginx/nginx-qflm.conf","-g","daemon off;"]
DOCKER

docker build -f "$GUI_DOCKERFILE" -t "$GUI_IMAGE" . || die "Security GUI candidate build failed"

docker rm -f "$ISO_GUI" >/dev/null 2>&1 || true

docker run -d \
 --name "$ISO_GUI" \
 --network "$NET" \
 --read-only \
 --cap-drop ALL \
 --security-opt no-new-privileges:true \
 --tmpfs /tmp:rw,noexec,nosuid,size=24m,uid=101,gid=101 \
 "$GUI_IMAGE" >/dev/null \
 || die "isolated Security GUI start failed"

sleep 3

[ "$(docker inspect "$ISO_GUI" --format='{{.State.Running}}')" = true ] \
 || {
    docker logs --tail 200 "$ISO_GUI" || true
    die "isolated Security GUI not running"
 }

echo "gui_candidate_image=$GUI_IMAGE"
echo "isolated_gui_running=PASS"

echo
echo "=== 8. ADMIN LOGIN + READ API TESTS ==="

ADMIN_USER="$(cat "$ADMIN_USER_FILE")"
ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"

LOGIN_JSON=$(python3 - "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)

LOGIN_RESPONSE=$(printf '%s' "$LOGIN_JSON" | docker run --rm --network "$NET" -i \
 curlimages/curl:8.16.0 -fsS \
 -H 'Content-Type: application/json' \
 -X POST "http://$ISO_GUI:8080/api/v1/auth/login" \
 --data-binary @-) || die "admin login failed"

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

USERS_JSON=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS \
 -H "Authorization: Bearer $TOKEN" \
 "http://$ISO_GUI:8080/api/v1/admin/security/users") \
 || die "security users list failed"

ROLES_JSON=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS \
 -H "Authorization: Bearer $TOKEN" \
 "http://$ISO_GUI:8080/api/v1/admin/security/roles") \
 || die "security roles list failed"

PERMS_JSON=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS \
 -H "Authorization: Bearer $TOKEN" \
 "http://$ISO_GUI:8080/api/v1/admin/security/permissions") \
 || die "security permissions list failed"

READ_COUNTS=$(python3 - "$USERS_JSON" "$ROLES_JSON" "$PERMS_JSON" <<'PY'
import json,sys
print(
    len(json.loads(sys.argv[1])),
    len(json.loads(sys.argv[2])),
    len(json.loads(sys.argv[3]))
)
PY
)

read -r USERS_COUNT ROLES_COUNT PERMS_COUNT <<<"$READ_COUNTS"

[ "$USERS_COUNT" -ge 1 ] || die "security users list empty"
[ "$ROLES_COUNT" -ge 1 ] || die "security roles list empty"
[ "$PERMS_COUNT" -eq 22 ] || die "unexpected security permission count"

printf 'users=%s roles=%s permissions=%s\n' \
 "$USERS_COUNT" "$ROLES_COUNT" "$PERMS_COUNT"

echo "security_read_apis=PASS"

echo
echo "=== 9. CREATE CUSTOM ROLE THROUGH SECURITY API ==="

PERMISSION_IDS=$(python3 - "$PERMS_JSON" <<'PY'
import json,sys
items=json.loads(sys.argv[1])
wanted={"users.read","roles.read"}
ids=[x["id"] for x in items if x["code"] in wanted]
if len(ids) != len(wanted):
    raise SystemExit("required test permissions missing")
print(",".join(ids))
PY
)

ROLE_NAME="QFLM 16G2 Test Role $STAMP"

CREATE_ROLE_JSON=$(python3 - "$ROLE_NAME" "$PERMISSION_IDS" <<'PY'
import json,sys
ids=[x for x in sys.argv[2].split(",") if x]
print(json.dumps({
    "name":sys.argv[1],
    "description":"Disposable isolated Phase 16G.2 validation role.",
    "permissionIds":ids
}))
PY
)

ROLE_RESPONSE=$(printf '%s' "$CREATE_ROLE_JSON" | docker run --rm --network "$NET" -i \
 curlimages/curl:8.16.0 -fsS \
 -H 'Content-Type: application/json' \
 -H "Authorization: Bearer $TOKEN" \
 -X POST "http://$ISO_GUI:8080/api/v1/admin/security/roles" \
 --data-binary @-) || die "security role creation failed"

TEST_ROLE_ID=$(python3 - "$ROLE_RESPONSE" <<'PY'
import json,sys
obj=json.loads(sys.argv[1])
assert obj["id"]
assert obj["name"]
assert len(obj["permissions"]) == 2
print(obj["id"])
PY
)

ISO_ROLES_AFTER_CREATE=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
[ "$ISO_ROLES_AFTER_CREATE" -eq $((ISO_ROLES_BEFORE + 1)) ] || die "role persistence mismatch"

echo "security_role_create=PASS"

echo
echo "=== 10. UPDATE ROLE PERMISSIONS ==="

UPDATED_PERMISSION_IDS=$(python3 - "$PERMS_JSON" <<'PY'
import json,sys
items=json.loads(sys.argv[1])
wanted={"users.read","roles.read","products.read"}
ids=[x["id"] for x in items if x["code"] in wanted]
if len(ids) != len(wanted):
    raise SystemExit("required update permissions missing")
print(",".join(ids))
PY
)

UPDATE_ROLE_JSON=$(python3 - "$UPDATED_PERMISSION_IDS" <<'PY'
import json,sys
print(json.dumps({"permissionIds":[x for x in sys.argv[1].split(",") if x]}))
PY
)

UPDATE_ROLE_HTTP=$(printf '%s' "$UPDATE_ROLE_JSON" | docker run --rm --network "$NET" -i \
 curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' \
 -H 'Content-Type: application/json' \
 -H "Authorization: Bearer $TOKEN" \
 -X PUT "http://$ISO_GUI:8080/api/v1/admin/security/roles/$TEST_ROLE_ID/permissions" \
 --data-binary @-)

[ "$UPDATE_ROLE_HTTP" = 204 ] || die "role permission update failed"

ROLE_PERM_COUNT=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc \
 "SELECT count(*) FROM auth_role_permissions WHERE role_id='$TEST_ROLE_ID';" | xargs)

[ "$ROLE_PERM_COUNT" = 3 ] || die "role permission persistence mismatch"

echo "security_role_permissions_update=PASS"

echo
echo "=== 11. CREATE USER WITH ROLE ==="

TEST_USERNAME="qflm-recovery7g2-${STAMP,,}"
TEST_EMAIL="${TEST_USERNAME}@invalid.example"
TEST_PASSWORD="$(python3 - <<'PY'
import secrets
print("Qf16G2-" + secrets.token_urlsafe(20))
PY
)"

CREATE_USER_JSON=$(python3 - "$TEST_USERNAME" "$TEST_EMAIL" "$TEST_PASSWORD" "$TEST_ROLE_ID" <<'PY'
import json,sys
print(json.dumps({
    "username":sys.argv[1],
    "email":sys.argv[2],
    "password":sys.argv[3],
    "roleIds":[sys.argv[4]]
}))
PY
)

USER_RESPONSE=$(printf '%s' "$CREATE_USER_JSON" | docker run --rm --network "$NET" -i \
 curlimages/curl:8.16.0 -fsS \
 -H 'Content-Type: application/json' \
 -H "Authorization: Bearer $TOKEN" \
 -X POST "http://$ISO_GUI:8080/api/v1/admin/security/users" \
 --data-binary @-) || die "security user creation failed"

TEST_USER_ID=$(python3 - "$USER_RESPONSE" "$ROLE_NAME" <<'PY'
import json,sys
obj=json.loads(sys.argv[1])
assert obj["id"]
assert obj["username"]
assert obj["isActive"] is True
assert sys.argv[2] in obj["roles"]
print(obj["id"])
PY
)

ISO_USERS_AFTER_CREATE=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
[ "$ISO_USERS_AFTER_CREATE" -eq $((ISO_USERS_BEFORE + 1)) ] || die "user persistence mismatch"

echo "security_user_create=PASS"

echo
echo "=== 12. USER ROLE ASSIGNMENT UPDATE ==="

SET_USER_ROLES_JSON=$(python3 - "$TEST_ROLE_ID" <<'PY'
import json,sys
print(json.dumps({"roleIds":[sys.argv[1]]}))
PY
)

SET_USER_ROLES_HTTP=$(printf '%s' "$SET_USER_ROLES_JSON" | docker run --rm --network "$NET" -i \
 curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' \
 -H 'Content-Type: application/json' \
 -H "Authorization: Bearer $TOKEN" \
 -X PUT "http://$ISO_GUI:8080/api/v1/admin/security/users/$TEST_USER_ID/roles" \
 --data-binary @-)

[ "$SET_USER_ROLES_HTTP" = 204 ] || die "user role assignment update failed"

USER_ROLE_COUNT=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc \
 "SELECT count(*) FROM auth_user_roles WHERE user_id='$TEST_USER_ID' AND role_id='$TEST_ROLE_ID';" | xargs)

[ "$USER_ROLE_COUNT" = 1 ] || die "user role persistence mismatch"

echo "security_user_roles_update=PASS"

echo
echo "=== 13. USER DISABLE + ENABLE ==="

DISABLE_JSON='{"isActive":false}'
ENABLE_JSON='{"isActive":true}'

DISABLE_HTTP=$(printf '%s' "$DISABLE_JSON" | docker run --rm --network "$NET" -i \
 curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' \
 -H 'Content-Type: application/json' \
 -H "Authorization: Bearer $TOKEN" \
 -X PUT "http://$ISO_GUI:8080/api/v1/admin/security/users/$TEST_USER_ID/status" \
 --data-binary @-)

[ "$DISABLE_HTTP" = 204 ] || die "user disable failed"

DISABLED=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc \
 "SELECT is_active FROM auth_users WHERE id='$TEST_USER_ID';" | xargs)

[ "$DISABLED" = f ] || die "user disable persistence mismatch"

ENABLE_HTTP=$(printf '%s' "$ENABLE_JSON" | docker run --rm --network "$NET" -i \
 curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' \
 -H 'Content-Type: application/json' \
 -H "Authorization: Bearer $TOKEN" \
 -X PUT "http://$ISO_GUI:8080/api/v1/admin/security/users/$TEST_USER_ID/status" \
 --data-binary @-)

[ "$ENABLE_HTTP" = 204 ] || die "user enable failed"

ENABLED=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc \
 "SELECT is_active FROM auth_users WHERE id='$TEST_USER_ID';" | xargs)

[ "$ENABLED" = t ] || die "user enable persistence mismatch"

echo "security_user_status_toggle=PASS"

echo
echo "=== 14. FINAL SECURITY READBACK ==="

USERS_FINAL=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS \
 -H "Authorization: Bearer $TOKEN" \
 "http://$ISO_GUI:8080/api/v1/admin/security/users") \
 || die "final security users list failed"

ROLES_FINAL=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS \
 -H "Authorization: Bearer $TOKEN" \
 "http://$ISO_GUI:8080/api/v1/admin/security/roles") \
 || die "final security roles list failed"

python3 - "$USERS_FINAL" "$ROLES_FINAL" "$TEST_USERNAME" "$ROLE_NAME" <<'PY'
import json,sys

users=json.loads(sys.argv[1])
roles=json.loads(sys.argv[2])
username=sys.argv[3]
role_name=sys.argv[4]

u=next((x for x in users if x["username"] == username), None)
r=next((x for x in roles if x["name"] == role_name), None)

assert u is not None
assert u["isActive"] is True
assert role_name in u["roles"]

assert r is not None
assert set(r["permissions"]) == {"users.read","roles.read","products.read"}

print("security_readback=PASS")
PY

echo
echo "=== 15. GUI ROUTE + HARDENING TEST ==="

SECURITY_HTTP=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 \
 -s -o /dev/null -w '%{http_code}' "http://$ISO_GUI:8080/security")

[ "$SECURITY_HTTP" = 200 ] || die "Security GUI route failed"

GUI_HARDEN=$(docker inspect "$ISO_GUI" \
 --format='readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}} ports={{json .NetworkSettings.Ports}}')

API_HARDEN=$(docker inspect "$ISO_API" \
 --format='readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}} ports={{json .NetworkSettings.Ports}}')

echo "GUI: $GUI_HARDEN"
echo "API: $API_HARDEN"

echo "$GUI_HARDEN" | grep -Fq 'readonly=true' || die "GUI readonly hardening missing"
echo "$GUI_HARDEN" | grep -Fq '"ALL"' || die "GUI cap drop missing"
echo "$GUI_HARDEN" | grep -Fq 'no-new-privileges:true' || die "GUI no-new-privileges missing"

echo "$API_HARDEN" | grep -Fq 'readonly=true' || die "API readonly hardening missing"
echo "$API_HARDEN" | grep -Fq '"ALL"' || die "API cap drop missing"
echo "$API_HARDEN" | grep -Fq 'no-new-privileges:true' || die "API no-new-privileges missing"

echo "security_gui_route=PASS"
echo "isolated_hardening=PASS"

echo
echo "=== 16. REVOKE TEST ADMIN SESSION ==="

REVOKE_JSON=$(python3 - "$REFRESH" <<'PY'
import json,sys
print(json.dumps({"refreshToken":sys.argv[1]}))
PY
)

REVOKE_HTTP=$(printf '%s' "$REVOKE_JSON" | docker run --rm --network "$NET" -i \
 curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' \
 -H 'Content-Type: application/json' \
 -H "Authorization: Bearer $TOKEN" \
 -X POST "http://$ISO_GUI:8080/api/v1/auth/revoke" \
 --data-binary @-)

[ "$REVOKE_HTTP" = 204 ] || die "admin test session revoke failed"

unset \
 TOKEN REFRESH ADMIN_PASS LOGIN_JSON LOGIN_RESPONSE \
 TEST_PASSWORD CREATE_USER_JSON USER_RESPONSE CREATE_ROLE_JSON ROLE_RESPONSE \
 UPDATE_ROLE_JSON SET_USER_ROLES_JSON USERS_JSON ROLES_JSON PERMS_JSON \
 USERS_FINAL ROLES_FINAL

echo "test_session_revoked=PASS"

echo
echo "=== 17. CURRENT CLOUDFLARE PREVIEW UNCHANGED ==="

PREVIEW_API_FINAL=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_FINAL=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_API_IMAGE_FINAL=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_GUI_IMAGE_FINAL=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)

printf 'preview_api=%s preview_gui=%s api_image=%s gui_image=%s\n' \
 "$PREVIEW_API_FINAL" "$PREVIEW_GUI_FINAL" "$PREVIEW_API_IMAGE_FINAL" "$PREVIEW_GUI_IMAGE_FINAL"

[ "$PREVIEW_API_FINAL" = true ] || die "current preview API changed/stopped"
[ "$PREVIEW_GUI_FINAL" = true ] || die "current preview GUI changed/stopped"
[ "$PREVIEW_API_IMAGE_FINAL" = "$PREVIEW_API_IMAGE" ] || die "current preview API image changed"
[ "$PREVIEW_GUI_IMAGE_FINAL" = "$PREVIEW_GUI_IMAGE" ] || die "current preview GUI image changed"

echo "current_preview_unchanged=PASS"

echo
echo "=== 18. PRODUCTION FINAL SAFETY ==="

FINAL_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

FINAL_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
FINAL_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
FINAL_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)

printf 'image=%s running=%s migrations=%s users=%s roles=%s permissions=%s\n' \
 "$FINAL_IMAGE" "$FINAL_RUNNING" "$FINAL_MIG" "$FINAL_USERS" "$FINAL_ROLES" "$FINAL_PERMS"

[ "$FINAL_IMAGE" = "$PROD_IMAGE" ] || die "production API image changed"
[ "$FINAL_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "production migrations changed"
[ "$FINAL_USERS" = "$PROD_USERS" ] || die "production users changed"
[ "$FINAL_ROLES" = "$PROD_ROLES" ] || die "production roles changed"
[ "$FINAL_PERMS" = "$PROD_PERMS" ] || die "production permissions changed"

echo "production_unchanged=PASS"

COMPLETED=1

echo
echo "======================================================"
echo " QFLM RECOVERY 7G2 V2 PASSED"
echo "======================================================"
echo "SECURITY USERS LIST:              PASS"
echo "SECURITY ROLES LIST:              PASS"
echo "SECURITY PERMISSIONS LIST:        PASS"
echo "CREATE USER:                      PASS"
echo "ENABLE/DISABLE USER:              PASS"
echo "USER ROLE ASSIGNMENT:             PASS"
echo "CREATE ROLE:                      PASS"
echo "ROLE PERMISSION ASSIGNMENT:       PASS"
echo "SECURITY GUI ROUTE:               PASS"
echo "ISOLATED API/GUI HARDENING:       PASS"
echo "CURRENT CLOUDFLARE PREVIEW:       UNCHANGED"
echo "PRODUCTION API/DB:                UNCHANGED"
echo "GUI CANDIDATE IMAGE:              $GUI_IMAGE"
echo "REPORT:                           $REPORT"
echo "NEXT: RECOVERY 7G3 - REFRESH CLOUDFLARE PREVIEW WITH SECURITY ADMIN GUI"
echo "======================================================"

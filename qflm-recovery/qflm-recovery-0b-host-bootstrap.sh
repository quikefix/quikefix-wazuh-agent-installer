#!/usr/bin/env bash
# QFLM RECOVERY 0B
# Fresh host bootstrap: base packages, Docker/Compose, .NET 10, QFLM directories.
# Does NOT install PostgreSQL/Redis or restore application state yet.

set -u
set -o pipefail
umask 077

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

echo "======================================================"
echo " QFLM RECOVERY 0B - HOST BOOTSTRAP"
echo "======================================================"

[ "$(id -u)" -eq 0 ] || die "run as root"

. /etc/os-release
[ "${ID:-}" = "ubuntu" ] || die "Ubuntu required"
[ "${VERSION_ID:-}" = "24.04" ] || die "Ubuntu 24.04 required"

echo
echo "=== 1. RESOURCE BASELINE ==="

CPU="$(nproc)"
MEM_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
ROOT_AVAIL_KB="$(df --output=avail / | tail -1 | xargs)"

echo "cpu=$CPU"
echo "memory_kb=$MEM_KB"
echo "root_available_kb=$ROOT_AVAIL_KB"

[ "$CPU" -ge 4 ] || die "minimum 4 CPUs required"
[ "$MEM_KB" -ge 7000000 ] || die "minimum ~8 GB RAM expected"
[ "$ROOT_AVAIL_KB" -ge 40000000 ] || die "minimum 40 GB free root space expected"

echo "resource_baseline=PASS"

echo
echo "=== 2. BASE PACKAGES ==="

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
  ca-certificates curl gnupg jq git unzip zip rsync openssl \
  lsb-release apt-transport-https software-properties-common \
  acl tree net-tools dnsutils iproute2

echo "base_packages=PASS"

echo
echo "=== 3. DOCKER OFFICIAL REPOSITORY ==="

apt-get remove -y \
  docker.io docker-compose docker-compose-v2 docker-doc docker-buildx \
  podman-docker containerd runc >/dev/null 2>&1 || true

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc \
  || die "Docker GPG key download failed"

chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update

apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker
systemctl is-active --quiet docker || die "Docker service not active"

echo "docker_install=PASS"

echo
echo "=== 4. DOCKER FUNCTION TEST ==="

docker run --rm hello-world >/tmp/qflm-docker-hello.txt 2>&1 \
  || { cat /tmp/qflm-docker-hello.txt; die "Docker hello-world failed"; }

grep -q "Hello from Docker" /tmp/qflm-docker-hello.txt \
  || die "Docker hello-world output unexpected"

rm -f /tmp/qflm-docker-hello.txt
echo "docker_runtime_test=PASS"

echo
echo "=== 5. .NET 10 SDK ==="

apt-get install -y dotnet-sdk-10.0 \
  || die ".NET 10 SDK installation failed"

dotnet --list-sdks | grep -q '^10\.' \
  || die ".NET 10 SDK not detected"

dotnet --list-runtimes | grep -q 'Microsoft.AspNetCore.App 10\.' \
  || die "ASP.NET Core 10 runtime not detected"

echo "dotnet10=PASS"

echo
echo "=== 6. QFLM DIRECTORY FOUNDATION ==="

install -d -m 0755 /opt/qflm
install -d -m 0755 /opt/qflm/app
install -d -m 0755 /opt/qflm/backups
install -d -m 0755 /opt/qflm/compose
install -d -m 0755 /opt/qflm/config
install -d -m 0755 /opt/qflm/logs
install -d -m 0700 /opt/qflm/secrets
install -d -m 0700 /opt/qflm/secrets/auth
install -d -m 0700 /opt/qflm/secrets/signing

chown -R root:root /opt/qflm
echo "qflm_directory_foundation=PASS"

echo
echo "=== 7. NON-ROOT DOCKER ACCESS ==="

if id nouman >/dev/null 2>&1; then
    usermod -aG docker nouman
    echo "nouman_docker_group=CONFIGURED"
else
    echo "nouman_docker_group=SKIPPED_USER_NOT_FOUND"
fi

echo
echo "=== 8. FINAL VERIFICATION ==="

echo "OS: $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "Kernel: $(uname -r)"
echo "CPU: $(nproc)"
free -h
df -h /

echo
docker --version
docker compose version
docker buildx version | head -1

echo
dotnet --version
dotnet --list-sdks
dotnet --list-runtimes | grep -E 'Microsoft\.(NETCore|AspNetCore)\.App 10\.'

echo
find /opt/qflm -maxdepth 2 -type d -printf '%m %p\n' | sort

echo
echo "======================================================"
echo " QFLM RECOVERY 0B PASSED"
echo "======================================================"
echo "DOCKER ENGINE:          PASS"
echo "DOCKER COMPOSE:         PASS"
echo "DOCKER BUILDX:          PASS"
echo ".NET 10 SDK/RUNTIME:    PASS"
echo "QFLM DIRECTORIES:       PASS"
echo "POSTGRESQL/REDIS:       NOT INSTALLED YET"
echo "APPLICATION:            NOT RESTORED YET"
echo "NEXT: RECOVERY 1 - DATA SERVICES + SECRET FOUNDATION"
echo "======================================================"

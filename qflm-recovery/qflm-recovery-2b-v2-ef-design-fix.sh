#!/usr/bin/env bash
set -u
set -o pipefail

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
cd "$ROOT" || exit 1

dotnet add src/QFLM.Api/QFLM.Api.csproj package Microsoft.EntityFrameworkCore.Design --version 10.0.4 >/dev/null

exec bash -c 'curl -fsSL https://raw.githubusercontent.com/quikefix/quikefix-wazuh-agent-installer/main/qflm-recovery/qflm-recovery-2b-core-domain-schema.sh | bash'

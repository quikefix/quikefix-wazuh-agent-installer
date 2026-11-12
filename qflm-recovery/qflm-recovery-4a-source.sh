#!/usr/bin/env bash
set -euo pipefail
ROOT=/opt/qflm/app/QuikeFix.LicenseManager
BASE=https://raw.githubusercontent.com/quikefix/quikefix-wazuh-agent-installer/main/qflm-recovery/recovery4-src
cd "$ROOT"
mkdir -p src/QFLM.Application/Licensing/Administration src/QFLM.Infrastructure/Licensing/Administration
curl -fsSL "$BASE/AdministrativeLicensing.cs" -o src/QFLM.Application/Licensing/Administration/AdministrativeLicensing.cs
curl -fsSL "$BASE/EfAdministrativeLicensingService.cs" -o src/QFLM.Infrastructure/Licensing/Administration/EfAdministrativeLicensingService.cs
python3 - <<'PY'
from pathlib import Path
p=Path("src/QFLM.Api/Program.cs")
s=p.read_text()
line="builder.Services.AddScoped<QFLM.Application.Licensing.Administration.IAdministrativeLicensingService, QFLM.Infrastructure.Licensing.Administration.EfAdministrativeLicensingService>();"
if line not in s: s=s.replace("builder.Services.AddControllers();",line+"\nbuilder.Services.AddControllers();")
p.write_text(s)
PY
dotnet build QuikeFix.LicenseManager.slnx -c Release
grep -q 'ActivationKeyHash' src/QFLM.Domain/Licenses/License.cs
grep -q '!l.Customer.IsActive' src/QFLM.Infrastructure/Licensing/EfLicensingService.cs
grep -q '!l.Product.IsActive' src/QFLM.Infrastructure/Licensing/EfLicensingService.cs
grep -q 'SubscriptionStatus.Active' src/QFLM.Infrastructure/Licensing/EfLicensingService.cs
grep -q 'LastHeartbeatSequence = 0' src/QFLM.Infrastructure/Licensing/Administration/EfAdministrativeLicensingService.cs
grep -q 'HighestLeaseSequence = 0' src/QFLM.Infrastructure/Licensing/Administration/EfAdministrativeLicensingService.cs
grep -q 'InstallationPublicKey = null' src/QFLM.Infrastructure/Licensing/Administration/EfAdministrativeLicensingService.cs
echo "RECOVERY4A=PASS"

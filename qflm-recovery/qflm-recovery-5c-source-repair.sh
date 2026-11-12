#!/usr/bin/env bash
set -euo pipefail

ROOT=/opt/qflm/app/QuikeFix.LicenseManager
PROGRAM=$ROOT/src/QFLM.SigningService/Program.cs

cd "$ROOT"

python3 - <<'PY'
from pathlib import Path
p=Path("/opt/qflm/app/QuikeFix.LicenseManager/src/QFLM.SigningService/Program.cs")
s=p.read_text()

def dedupe_route(src, marker):
    hits=[]
    start=0
    while True:
        i=src.find(marker,start)
        if i<0: break
        hits.append(i)
        start=i+1
    if len(hits)<=1:
        return src
    # remove later duplicate handler block(s), each ending at the next "\n});"
    for i in reversed(hits[1:]):
        j=src.find("\n});",i)
        if j<0:
            raise SystemExit(f"Could not find end of duplicate block for {marker}")
        src=src[:i]+src[j+4:]
    return src

s=dedupe_route(s,'app.MapPost("/internal/v1/offline-license/issue"')
s=dedupe_route(s,'app.MapPost("/internal/v1/offline-license/renew"')

# Ensure DI registration is single as well
needle='builder.Services.AddSingleton<OfflineLicenseEnvelopeFactory>();'
while s.count(needle)>1:
    pos=s.rfind(needle)
    s=s[:pos]+s[pos+len(needle):]

p.write_text(s)
PY

ISSUE_COUNT=$(grep -F -c 'app.MapPost("/internal/v1/offline-license/issue"' "$PROGRAM" || true)
RENEW_COUNT=$(grep -F -c 'app.MapPost("/internal/v1/offline-license/renew"' "$PROGRAM" || true)
FACTORY_COUNT=$(grep -F -c 'builder.Services.AddSingleton<OfflineLicenseEnvelopeFactory>();' "$PROGRAM" || true)

echo "ISSUE_ROUTES=$ISSUE_COUNT RENEW_ROUTES=$RENEW_COUNT FACTORY_DI=$FACTORY_COUNT"

[ "$ISSUE_COUNT" = 1 ] || { echo "STOP: issue route count invalid"; exit 1; }
[ "$RENEW_COUNT" = 1 ] || { echo "STOP: renew route count invalid"; exit 1; }
[ "$FACTORY_COUNT" = 1 ] || { echo "STOP: factory DI count invalid"; exit 1; }

dotnet build QuikeFix.LicenseManager.slnx -c Release

echo "QFLM RECOVERY 5C SOURCE REPAIR PASSED"

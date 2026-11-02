#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 -B tests/preservation_origin/test_contract.py -v > "$work/static-source-closure.json"
python3 -B tests/preservation_origin/generate_fixture.py --output "$work" > "$work/source-generation.json"
swiftc -swift-version 6 -parse-as-library -D SIDESIGN_PROFILE_TRANSPORT_TESTING "$work/Integration.swift" -o "$work/transport"
"$work/transport" | tee "$work/transport.json"
# Separately compile normal production visibility without the test-only hook.
swiftc -swift-version 6 -parse-as-library -emit-module -module-name OriginProductionFixture "$work/Library.swift" -emit-module-path "$work/OriginProductionFixture.swiftmodule"
python3 - "$work" <<'PY'
import pathlib,sys
w=pathlib.Path(sys.argv[1]);prefix='import Foundation\nimport OriginProductionFixture\n'
(w/'receipt.swift').write_text(prefix+'func forge(_ p: ProvisioningProfile) { _ = AppleProfileEvidence(profile:p, role:.existing, operationID:UUID()) }\n')
(w/'operation.swift').write_text(prefix+'func forge(_ t:Team,_ s:Session,_ h:SideSignHeaders) throws { _ = try AppleProfileOperation(team:t,session:s,bundleIdentifier:"app",headers:h,validateOwnership:{}) }\n')
(w/'hook.swift').write_text(prefix+'let forbidden = AppleProfileTransportTesting.protocolClasses\n')
(w/'positive.swift').write_text(prefix+'func create(_ p:DeveloperPortal,_ t:Team,_ s:Session) throws -> AppleProfileOperation { try p.makePreservationProfileOperation(team:t,session:s,bundleIdentifier:"app",validateOwnership:{}) }\n')
PY
swiftc -swift-version 6 -typecheck -I "$work" "$work/positive.swift"
for name in receipt operation hook; do
  if swiftc -swift-version 6 -typecheck -I "$work" "$work/$name.swift" > "$work/$name.log" 2>&1; then
    echo "Unexpected public trust construction: $name" >&2; exit 1
  fi
done
python3 - "$work" <<'PY'
import json,pathlib,sys
w=pathlib.Path(sys.argv[1]);expected=json.loads(pathlib.Path('tests/preservation_origin/expected-cases.json').read_text())
lines=(w/'transport.json').read_text().splitlines();assert len(lines)==1;r=json.loads(lines[0])
assert set(r)=={'schema','status','cases','network_executed','platform_tls_executed','cms_verified','device_executed'}
assert r['schema']=='preservation-origin-transport-v1' and r['status']=='PASS' and r['cases']==expected['transport']
assert all(r[k] is False for k in ['network_executed','platform_tls_executed','cms_verified','device_executed'])
for file,symbol in [('receipt','AppleProfileEvidence'),('operation','AppleProfileOperation')]:
 text=(w/(file+'.log')).read_text();assert symbol in text and ('inaccessible' in text or 'no accessible initializers' in text)
assert 'AppleProfileTransportTesting' in (w/'hook.log').read_text() and 'cannot find' in (w/'hook.log').read_text()
print(json.dumps({'schema':'preservation-origin-visibility-v1','status':'PASS','cases':expected['compile_negative'],'device_executed':False},sort_keys=True))
PY

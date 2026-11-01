#!/bin/bash
set -euo pipefail
if [[ $# != 4 || "$1" != "--openssl-root" || "$3" != "--python" ]]; then
  echo "usage: run_public.sh --openssl-root <same-run OpenSSL 3.5.9 install> --python <absolute harness interpreter>" >&2; exit 2
fi
# Use the same harness interpreter as the C lane, never PATH-selected Python.
# Preserve the invocation path (including a valid executable symlink).
python="$4"
if [[ "$python" != /* || ! -f "$python" || ! -x "$python" ]]; then
  echo "invalid bound harness interpreter" >&2; exit 2
fi
openssl_root=$(cd "$2" && pwd -P)
cd "$(dirname "$0")/../.."
root=$(pwd -P)
mini="$root/Dependencies/minimuxer"
core="$mini/DeviceGateway/ProvisioningCMSCore"
crypto="$openssl_root/lib/libcrypto.a"
if [[ ! -f "$crypto" ]]; then crypto="$openssl_root/lib64/libcrypto.a"; fi
test -f "$crypto"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/version.c" <<'C'
#include <openssl/crypto.h>
#include <openssl/opensslv.h>
#include <string.h>
int main(void) {
 return !(OPENSSL_VERSION_MAJOR==3 && OPENSSL_VERSION_MINOR==5 && OPENSSL_VERSION_PATCH==9 &&
          strncmp(OpenSSL_version(OPENSSL_VERSION),"OpenSSL 3.5.9 ",14)==0);
}
C
clang -I "$openssl_root/include" "$work/version.c" "$crypto" -o "$work/version"
"$work/version"
mkdir "$work/module"
printf 'module ProvisioningCMSCore { header "%s" export * }\n' "$core/include/profile_cms.h" > "$work/module/module.modulemap"
clang -fPIC -I "$openssl_root/include" -I "$core/include" -c "$core/profile_cms.c" -o "$work/profile_cms.o"
swiftc -emit-module -emit-library -module-name LibimobiledeviceGateway \
  "$mini/DeviceGateway/libimobiledevice/ProvisioningCMSVerifier.swift" "$work/profile_cms.o" "$crypto" \
  -I "$work/module" -emit-module-path "$work/LibimobiledeviceGateway.swiftmodule" \
  -o "$work/libLibimobiledeviceGateway.dylib"
cp tests/preservation_der/PublicCases.swift "$work/main.swift"
swiftc "$mini/Sources/ProfileCMSVerifier.swift" \
  SideStore/Core/Operations/PipelineOperations/PreservedProfileDecoder.swift "$work/main.swift" \
  -I "$work" -I "$work/module" -L "$work" -lLibimobiledeviceGateway \
  -Xlinker -rpath -Xlinker "$work" -o "$work/public"
"$python" -B tests/preservation_der/fetch_public_fixtures.py --output "$work/public-inputs" >/dev/null
"$work/public" "$work/public-inputs" "$mini/TestsCMS/approved-inner-provenance.json" | tee "$work/result.json"
"$python" - "$work/result.json" <<'PY'
import json,pathlib,sys
suffixes=['outer-role-authenticated','inner-pinned-role-authenticated','signer-diagnostic-facade','complete-authority-bound','outer-tamper-rejected','inner-tamper-rejected','inner-cannot-be-outer-role','outer-cannot-be-inner-role']
expected=[f'public-{i}-{s}' for i in range(2) for s in suffixes]+[f'public-{i}-cross-profile-binding-rejected' for i in range(2)]
lines=pathlib.Path(sys.argv[1]).read_text().splitlines();assert len(lines)==1
r=json.loads(lines[0]);assert set(r)=={'schema','status','cases','cms_verified','device_executed'}
assert r['schema']=='preservation-der-public-v1' and r['status']=='PASS'
assert r['cases']==expected and r['cms_verified'] is True and r['device_executed'] is False
assert r['cases']==json.loads(pathlib.Path('tests/preservation_der/expected-cases.json').read_text())['public']
PY

#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
output="$(mktemp -d)"
trap 'rm -rf "$output"' EXIT
python3 "$root/.ci/initial-provider-rejection/generate.py" --output "$output" --sidesign-root "${SIDESIGN_ROOT:-$root/Dependencies/SideSign}"
swiftc -swift-version 6 -parse-as-library "$output"/*.swift -o "$output/tests"
"$output/tests"
# The production constructor must remain unavailable outside Authentication.swift.
cat > "$output/Forge.swift" <<'SWIFT'
func cannotForgeInitialRejection() {
    _ = OwnedODAInitialProviderRejection(context: FixtureOwnedODAContext())
}
SWIFT
if swiftc -swift-version 6 -parse-as-library "$output"/*.swift -o "$output/forged" > "$output/forge.log" 2>&1; then
    echo "ERROR: Initial rejection constructor became externally accessible" >&2
    exit 1
fi
grep -F "'fileprivate' protection level" "$output/forge.log"
echo "INITIAL_PROVIDER_REJECTION_CONSTRUCTOR_PRIVATE_PASS"

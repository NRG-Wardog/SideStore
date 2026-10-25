#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
python3 "$root/.ci/owned-oda/generate_identity.py" --output "$tmp"
swiftc -swift-version 6 -parse-as-library "$tmp/Identity.swift" "$root/.ci/owned-oda/IdentityCases.swift" -o "$tmp/identity"
"$tmp/identity"

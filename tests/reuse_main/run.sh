#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 tests/reuse_main/test_contract.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work/Registry.swift" <<'PY'
from pathlib import Path
import sys
source = Path('SideStore/Core/Operations/OperationContexts.swift').read_text()
Path(sys.argv[1]).write_text('import Foundation\n' + source[source.index('enum V3ValidatedReuseMainRegistry {'):])
PY
swiftc -swift-version 6 "$work/Registry.swift" tests/reuse_main/RegistryCases.swift -o "$work/registry"
"$work/registry"

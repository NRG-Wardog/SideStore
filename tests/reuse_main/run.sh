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
python3 - "$work/Explanation.swift" <<'PY'
from pathlib import Path
import sys
source = Path('SideStore/Core/Operations/PipelineExecutionHandler.swift').read_text()
source = source.split('// V3_REUSE_MAIN_EXPLANATION_BEGIN\n', 1)[1].split('// V3_REUSE_MAIN_EXPLANATION_END', 1)[0]
Path(sys.argv[1]).write_text('import Foundation\n' + source)
PY
swiftc -swift-version 6 -parse-as-library "$work/Explanation.swift" tests/reuse_main/ExplanationCases.swift -o "$work/explanation"
"$work/explanation"

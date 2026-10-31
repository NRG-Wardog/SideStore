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
swiftc -swift-version 6 "$work/Registry.swift" tests/reuse_main/Lifecycle.swift -o "$work/lifecycle"
"$work/lifecycle"
python3 - "$work/Explanation.swift" <<'PY'
from pathlib import Path
import sys
source = Path('SideStore/Core/Operations/PipelineExecutionHandler.swift').read_text()
source = source.split('// V3_REUSE_MAIN_EXPLANATION_BEGIN\n', 1)[1].split('// V3_REUSE_MAIN_EXPLANATION_END', 1)[0]
Path(sys.argv[1]).write_text('import Foundation\n' + source)
PY
swiftc -swift-version 6 -parse-as-library "$work/Explanation.swift" tests/reuse_main/ExplanationCases.swift -o "$work/explanation"
"$work/explanation"
python3 tests/reuse_main/generate_producer_consumer.py "$work/producer-consumer"
swiftc -swift-version 6 -parse-as-library "$work/producer-consumer/Fingerprint.swift" "$work/producer-consumer/ProducerConsumer.swift" -o "$work/producer-consumer/native"
"$work/producer-consumer/native" | tee "$work/producer-consumer/native.log"
python3 - "$work/producer-consumer/native.log" <<'PY'
import json,sys
lines=open(sys.argv[1]).read().splitlines()
assert len(lines)==1
result=json.loads(lines[0])
assert result['schema']=='reuse-main-producer-consumer-v1' and result['status']=='PASS'
assert result['device_executed'] is False
assert result['cases']==['staged-without-ack-not-enrolled','failed-ack-not-enrolled','actual-producer-ack-consumer-recovers-history-only','original-cache-unchanged-without-generation','missing-signed-marker-not-enrolled','certificate-profile-mismatch-not-enrolled','actual-fingerprint-source-drift-rejected']
PY

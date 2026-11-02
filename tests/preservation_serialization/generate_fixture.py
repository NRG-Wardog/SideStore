"""Extract the actual production lane; do not reimplement its scheduler."""
from pathlib import Path
import argparse, hashlib, json
from test_contract import validate

p = argparse.ArgumentParser()
p.add_argument('--repo', '--candidate-root', type=Path, required=True)
p.add_argument('--out', '--output', type=Path, required=True)
a = p.parse_args()
root = a.repo.resolve()
count = validate(root)
source = root / 'SideStore/Core/Operations/PipelineRunner.swift'
cases = root / 'tests/preservation_serialization/Cases.swift'
helper = source.read_text().split('// V3_PROFILE_TRANSACTION_LANE_BEGIN\n')[1].split('// V3_PROFILE_TRANSACTION_LANE_END')[0]
a.out.mkdir(parents=True, exist_ok=True)
generated = a.out / 'preservation-serialization.swift'
admission = source.read_text().split('        func checkTransactionAdmission() throws {', 1)[1].split('        debugLog("[AppManager] performOperation:', 1)[0]
admission = '        func checkTransactionAdmission() throws {' + admission
wrapper = """
func makeAdmission(group: FixtureGroup, progress: FixtureProgress, operation: String,
                   transactionAdmission: FixtureAdmission? = nil,
                   refreshAdmission: (() throws -> Void)? = nil) -> () throws -> Void {
    let transactionProgress = progress.progress(for: operation)
""" + admission + "\n    return checkTransactionAdmission\n}\n"
runner_text = source.read_text()
start = runner_text.index('    func performOperation(for operation:')
end = runner_text.index('\n', runner_text.index('            let result = try await self.performPipeline(', start))
# Exact common-entry prefix, including capture, defer, both admission calls,
# acquisition, verification initialization and actual admission forwarding.
# The platform pipeline is an inert awaited boundary; persistence is separately
# source-guarded, not claimed to run in this fixture.
integration = runner_text[start:end] + '\n            _ = result\n        } catch { throw error }\n    }\n'
doubles = (root / 'tests/preservation_serialization/IntegrationDoubles.swift').read_text()
integration = 'extension FixtureRunner {\n' + integration + '}\n'
generated.write_text('import Foundation\n' + helper + '\n' + wrapper + doubles + integration + cases.read_text())
receipt = {'source_guard_count': count, 'swift_executed': False, 'device_executed': False,
           'inputs': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [source, cases, root / 'tests/preservation_serialization/IntegrationDoubles.swift']},
           'generated_sha256': hashlib.sha256(generated.read_bytes()).hexdigest()}
(a.out / 'sources.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt))

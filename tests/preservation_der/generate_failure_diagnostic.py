"""Failure-only synthetic diagnostic. Never a qualification source or result.
Only adds line/category logging; primary product bytes and its failure stay intact.
"""
import argparse,hashlib,json,pathlib,re
ROOT=pathlib.Path(__file__).resolve().parents[2]
SOURCE=ROOT/'SideStore/Core/Operations/PipelineOperations/PreservedProfileDecoder.swift'
def instrument(source):
 lines=source.splitlines();output=[]
 for n,line in enumerate(lines,1):
  if 'private static func check(_ condition: Bool)' in line or 'private static func bindingCheck(_ condition: Bool)' in line:
   line=line.replace('_ condition: Bool)', '_ condition: Bool, sourceLine: Int = #line)')
  if 'private func fail(_ parser: XMLParser)' in line:
   line=line.replace('_ parser: XMLParser)', '_ parser: XMLParser, sourceLine: Int = #line)').replace('invalid = true;', 'diagnosticLog("callback line=\\(sourceLine)"); invalid = true;')
  loc='sourceLine' if 'if !condition { throw Failure.' in line else str(n)
  line=re.sub(r'throw Failure\.(malformed|unsupported|inconsistent)',lambda m:f'throw diagnosticFailure(.{m[1]}, line: {loc})',line)
  output.append(line)
 return '#sourceLocation(file: "PreservedProfileDecoder.swift", line: 1)\n'+'\n'.join(output)+'\n#sourceLocation()\n'+HELPERS
HELPERS=r'''
private final class DiagnosticTrace: @unchecked Sendable {
    static let shared = DiagnosticTrace()
    private let lock = NSLock()
    private var count = 0
    func record(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        guard count < 12 else { return }; count += 1
        FileHandle.standardError.write(Data(("DER_DIAGNOSTIC " + value + "\n").utf8))
    }
}
private func diagnosticLog(_ value: String) { DiagnosticTrace.shared.record(value) }
private func diagnosticFailure(_ reason: PreservedProfileDecoder.Failure, line: Int) -> PreservedProfileDecoder.Failure {
    diagnosticLog("category=\(reason) line=\(line)"); return reason
}
'''
MAIN=r'''
let diagnosticInput = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: String]
let diagnosticOuter = Data(base64Encoded: diagnosticInput["outer"]!)!
let diagnosticInner = Data(base64Encoded: diagnosticInput["inner"]!)!
do {
    diagnosticLog("stage=outer-start")
    _ = try PreservedProfileDecoder.decodeOuter(verifiedOuterXML: diagnosticOuter)
    diagnosticLog("stage=outer-pass")
    _ = try PreservedProfileDecoder.decode(verifiedOuterXML: diagnosticOuter, verifiedInnerDER: diagnosticInner)
    diagnosticLog("stage=full-pass-not-qualification")
} catch {
    if let failure = error as? PreservedProfileDecoder.Failure { diagnosticLog("stage=failed category=\(failure)") }
    else { diagnosticLog("stage=failed category=other") }
}
'''
def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
 source=SOURCE.read_text();cases=json.loads((ROOT/'tests/preservation_der/swift-cases.json').read_text())['cases'];baseline=cases[0]
 assert baseline['name']=='baseline' and baseline['accept'] is True
 (a.output/'main.swift').write_text(instrument(source)+MAIN)
 (a.output/'baseline.json').write_text(json.dumps({k:baseline[k] for k in ['outer','inner']}))
 print('DER_DIAGNOSTIC_SOURCE sha256='+hashlib.sha256(source.encode()).hexdigest()+' qualification=false')
if __name__=='__main__':main()

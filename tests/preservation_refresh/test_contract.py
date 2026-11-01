"""Conditional DER equivalence source closure; native cases are separate."""
import importlib.util
from pathlib import Path
import tempfile, unittest
ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('fixture_generator',HERE/'generate_fixture.py')
generator=importlib.util.module_from_spec(spec);spec.loader.exec_module(generator)
class Contract(unittest.TestCase):
 def test_actual_policy_and_decoder_source_closure(self):
  with tempfile.TemporaryDirectory() as directory:
   out=Path(directory);generator.generate(out);text=(out/'Integration.swift').read_text()
   decoder=(ROOT/'SideStore/Core/Operations/PipelineOperations/PreservedProfileDecoder.swift').read_text()
   self.assertIn(decoder,text)
   for name in ['enum PreservedProfilePolicy {','struct V3PreservationRefreshState:','private func fetchPreservingInstalledAuthorization()']:
    self.assertEqual(text.count(name),1)
   self.assertIn('enum ProfileCMSVerifier {',text)
   self.assertIn('throw ProfileCMSVerificationError.unsupportedSigner',text)
   self.assertNotIn('struct PreservedProfileDecoder',text)
 def test_raw_first_strict_der_only_upgrade(self):
  s=(ROOT/'SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift').read_text()
  adapter=s[s.index('struct V3PreservationRefreshState:'):]
  self.assertIn('catch PreservedProfilePolicy.Failure.embeddedDERDiffer',adapter)
  self.assertIn('catch PreservedProfilePolicy.Failure.changedAuthorization',adapter)
  self.assertLess(adapter.index('hasOnlyEmbeddedDERDifference'),adapter.index('let inputs = try authenticatedTargetInputs',adapter.index('static func finish')))
  self.assertIn('try PreservedProfilePolicy.sameRawTarget',adapter)
  self.assertIn('decoded.normalizedInnerAuthority',adapter)
  self.assertIn('ProfileCMSVerifier.authenticateOuter(bytes)',adapter)
  self.assertIn('ProfileCMSVerifier.authenticateInner(nestedCMS)',adapter)
  self.assertIn('guard try PreservedProfilePolicy.Value(verified.raw) == PreservedProfilePolicy.Value(raw[index])',adapter)
 def test_budget_deadline_and_no_dynamic_trust_marker(self):
  s=(ROOT/'SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift').read_text()
  adapter=s[s.index('struct V3PreservationRefreshState:'):]
  for required in ['inventory.count <= 512','addingReportingOverflow','bytes.count <= 1_048_576','next <= 32 * 1024 * 1024','systemUptime - started <= 20','try Task.checkCancellation()']:
   self.assertIn(required,adapter)
  self.assertIn('let candidate = try authenticatedInput(candidateData, phase: "candidate", admission: admission, started: started)\n        try checkWork(admission, started: started)',adapter)
  self.assertIn('let candidate = try Self.authenticatedInput(candidateData, phase: "freshCandidate", admission: admission, started: started)\n            try Self.checkWork(admission, started: started)',adapter)
  self.assertNotIn('Task.detached',adapter)
  self.assertNotIn('raw["verified"]',s)
  self.assertIn('fileprivate init(raw: [String: Any], authenticatedInner:',s)
 def test_unknown_signer_diagnostic_never_becomes_authority(self):
  source=(ROOT/'SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift').read_text()
  diagnostic=generator.extract(source,'catch ProfileCMSVerificationError.unsupportedSigner {')
  self.assertEqual(diagnostic.count('try checkWork(admission, started: started)'),2)
  self.assertIn('ProfileCMSVerifier.diagnoseInnerSigner(nestedCMS)',diagnostic)
  self.assertIn('throw V3RefreshSelectionFailure(reason: .preservationAuthorityConflict',diagnostic)
  self.assertNotIn('return ',diagnostic)
  self.assertIn('evidence.chain == .passed',diagnostic)
  self.assertIn('evidence.signature == .passed',diagnostic)
  self.assertIn('evidence.temporal == .passed',diagnostic)
  selection=generator.extract(source,'struct V3RefreshSelectionFailure:')
  self.assertIn('Self.validCMSSignerDiagnostic(diagnostic)',selection)
  self.assertIn('value.utf8.count <= 200',selection)
  self.assertIn('fields[6] == "failed"',selection)
if __name__=='__main__':unittest.main()

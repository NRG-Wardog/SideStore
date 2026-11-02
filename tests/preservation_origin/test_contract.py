from pathlib import Path
import hashlib,importlib.util,json,tempfile,unittest
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1]
spec=importlib.util.spec_from_file_location('origin_generator',HERE/'generate_fixture.py');g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g)
class Contract(unittest.TestCase):
 def test_actual_transport_model_receipt_and_consumer_closure(self):
  with tempfile.TemporaryDirectory() as t:
   o=Path(t);g.generate(o);generated=(o/'Integration.swift').read_text();library=(o/'Library.swift').read_text()
   operation=(g.SIDE/'DeveloperPortal/AppleProfileOperation.swift').read_text()
   self.assertIn(operation,generated);self.assertIn(operation,library)
   model=(g.SIDE/'Models/ProvisioningProfile.swift').read_text().replace('import CodeSignKit\n','')
   self.assertIn(model,generated)
   consumer=g.extract((ROOT/'SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift').read_text(),'struct V3AppleProfileOriginEvidence:')
   self.assertIn(consumer,generated)
   r=json.loads((o/'sources.json').read_text())
   for p,h in r['inputs'].items():self.assertEqual(hashlib.sha256((ROOT/p).read_bytes()).hexdigest(),h)
 def test_production_mint_cannot_be_forged_by_test_protocol(self):
  source=(g.SIDE/'DeveloperPortal/AppleProfileOperation.swift').read_text()
  self.assertIn('fileprivate init(profile:',source);self.assertIn('fileprivate init(team:',source)
  self.assertIn('#if SIDESIGN_PROFILE_TRANSPORT_TESTING',source)
  self.assertIn('configuration.protocolClasses = []',source)
  self.assertIn('configuration.protocolClasses = AppleProfileTransportTesting.protocolClasses',source)
  cases=(HERE/'TransportCases.swift').read_text()
  self.assertNotIn('AppleProfileEvidence(',cases);self.assertNotIn('AppleProfileOperation(',cases)
  self.assertIn('makePreservationProfileOperation(',cases)
 def test_finite_native_cases_and_no_real_network_claim(self):
  e=json.loads((HERE/'expected-cases.json').read_text());self.assertEqual(len(e['transport']),58);self.assertEqual(len(set(e['transport'])),58)
  self.assertEqual(len(e['compile_negative']),3)
  s=(HERE/'TransportCases.swift').read_text()
  for name in e['transport'][:38]:self.assertIn('"'+name+'"',s)
  suffix=[]
  for label in ['missing-id','missing-uuid','missing-both']:
   self.assertIn('"'+label+'"',s)
   for phase in ['existing','candidate']:suffix.append('origin-'+phase+'-envelope-'+label+'-accepted')
  for label in ['empty-id','nonascii-id','empty-uuid','malformed-uuid','wrongtype-id','wrongtype-uuid']:
   self.assertIn('"'+label+'"',s)
   for phase in ['existing','candidate']:suffix.append('origin-'+phase+'-envelope-'+label+'-rejected')
  suffix.append('origin-envelope-absent-embedded-uuid-mismatch-rejected')
  suffix.append('origin-task-cancelled-midstream-no-generation')
  self.assertEqual(e['transport'][38:],suffix)
  for phase in ['existing','candidate']:
   for result in ['accepted','rejected']:self.assertIn('"origin-'+phase+'-envelope-"+label+"-'+result+'"',s)
  self.assertIn('override class func canInit(with request:URLRequest)->Bool {true}',s)
  self.assertIn('"platform_tls_executed":false',s);self.assertIn('"cms_verified":false',s)
 def test_candidate_receipt_is_mandatory_and_historical_is_not_authority(self):
  consumer=g.extract((ROOT/'SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift').read_text(),'struct V3AppleProfileOriginEvidence:')
  self.assertIn('let candidate: AppleProfileEvidence',consumer)
  self.assertNotIn('AppleProfileEvidence?',consumer)
  self.assertNotIn('let installed:',consumer)
  self.assertIn('candidate.cmsData == bytes',consumer)
  self.assertIn('operation.authorize(candidate, exactCMS: bytes)',consumer)
 def test_visibility_checks_use_unflagged_actual_library(self):
  s=(HERE/'run.sh').read_text()
  self.assertIn('-D SIDESIGN_PROFILE_TRANSPORT_TESTING "$work/Integration.swift"',s)
  self.assertIn('-module-name OriginProductionFixture "$work/Library.swift"',s)
  self.assertIn('swiftc -swift-version 6 -typecheck -I "$work" "$work/positive.swift"',s)
  self.assertIn('for name in receipt operation hook',s)
  self.assertIn('test_contract.py -v > "$work/static-source-closure.json"',s)
  self.assertIn('--output "$work" > "$work/source-generation.json"',s)
if __name__=='__main__':unittest.main()

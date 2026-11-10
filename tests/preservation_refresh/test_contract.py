"""Actual-source historical constraints/candidate authority closure, not native proof."""
import importlib.util,json,re
from pathlib import Path
import tempfile,unittest
ROOT=Path(__file__).resolve().parents[2];HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('fixture_generator',HERE/'generate_fixture.py')
generator=importlib.util.module_from_spec(spec);spec.loader.exec_module(generator)
class Contract(unittest.TestCase):
 def source(self):return (ROOT/'SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift').read_text()
 def test_actual_policy_decoder_wrapper_and_consumer_source_closure(self):
  with tempfile.TemporaryDirectory() as directory:
   out=Path(directory);generator.generate(out);text=(out/'Integration.swift').read_text()
   self.assertIn((ROOT/'SideStore/Core/Operations/PipelineOperations/PreservedProfileDecoder.swift').read_text(),text)
   for name in ['enum PreservedProfilePolicy {','struct HistoricalConstraintSnapshot:','struct V3PreservationRefreshState:',
                'private func fetchPreservingInstalledAuthorization()','func installPreservationProvisioningProfile(',
                'private func isRetriableRemotePairingError(']:self.assertEqual(text.count(name),1)
   self.assertIn('enum ProfileCMSVerifier {',text)
   self.assertIn('try await minimuxer.core.installProvisioningProfile(profile: profileData)',text)
 def test_old_profiles_are_constraints_never_candidate_provenance(self):
  source=self.source();prepare=generator.extract(source,'    static func prepare(')
  self.assertIn('historicalConstraintInput',prepare)
  self.assertNotIn('origin:',prepare);self.assertNotIn('authorizeCandidate',prepare)
  adapter=generator.extract(source,'struct V3PreservationRefreshState:')
  self.assertNotIn('authenticateInner(',adapter);self.assertNotIn('requiredOriginProfiles',adapter)
  candidate=generator.extract(source,'    private static func authenticatedCandidateInput(')
  self.assertEqual(candidate.count('try origin.authorizeCandidate(bytes)'),2)
  self.assertLess(candidate.index('authorizeCandidate'),candidate.index('normalizedComparisonInput'))
  finish=generator.extract(source,'    static func finish(')
  self.assertIn('guard let origin else',finish)
  self.assertIn('profilesByUUID[model.uuid] == nil',finish)
  fetch=generator.extract((ROOT/'SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift').read_text(),'private func fetchPreservingInstalledAuthorization()')
  self.assertNotIn('requiredOriginProfiles',fetch);self.assertNotIn('installedEvidence',fetch)
  self.assertEqual(fetch.count('corroborateExisting('),1)
  self.assertIn('installedCMS: supplied.data',fetch)
  self.assertIn('candidateEvidence = try await operation.generateCandidate',fetch)
 def test_all_inventory_and_combined_budgets_no_replay(self):
  source=self.source();adapter=generator.extract(source,'struct V3PreservationRefreshState:')
  for required in ['inventory.count <= 512','addingReportingOverflow','bytes.count <= 1_048_576','next <= 32 * 1024 * 1024','systemUptime - started <= 20','try Task.checkCancellation()',
   'multiset(inventory) == Self.multiset(originalInventory)','prepared.originalInventory + [candidateData]',
   'historical.profilesByUUID.allSatisfy','byUUID[candidate.uuid] == candidateData']:self.assertIn(required,adapter)
  self.assertNotIn('Task.detached',adapter);self.assertNotIn('raw["verified"]',source)
  wrapper=(ROOT/'SideStore/Core/DeviceApi/MinimuxerWrapper.swift').read_text()
  single=generator.extract(wrapper,'func installPreservationProvisioningProfile(')
  self.assertNotIn('withRemotePairingRetry',single);self.assertNotIn('catch',single)
  self.assertIn('try await installPreservationProvisioningProfile',source)
  final=source[source.index('before = try await validateFreshPreservationSnapshot(profiles)'):source.index('preservationMutationDispatched = true')]
  self.assertLess(final.index('try await dbContext.perform'),final.index('validateOriginAdmission()'))
 def test_literal_native_case_markers_are_current(self):
  expected=json.loads((HERE/'expected-cases.json').read_text())
  # Catch stale literal emitters even on hosts without Swift. Dynamic loop
  # expansion and exact ordering remain enforced by run.sh's native manifest.
  for filename in ['IntegrationCases.swift','AuthenticatedAdapterCases.swift','OriginAdapterCases.swift']:
   source=(HERE/filename).read_text()
   literals=re.findall(r'passed\.append\("([^"\n]+)"\)',source)
   self.assertTrue(literals,filename)
   for label in literals:self.assertIn(label,expected['integration'],filename)
  source=(HERE/'IntegrationCases.swift').read_text()
  self.assertIn('passed.append("provided-profile-no-fresh-origin-rejected")',source)
  self.assertNotIn('provided-profile-same-authority-no-portal',source)
  self.assertIn('precondition(PortalProbe.shared.corroboratedUUIDs==[fresh.uuid])',source)
 def test_manifest_reconciliation_and_honest_claims(self):
  expected=json.loads((HERE/'expected-cases.json').read_text());reconciled=json.loads((HERE/'historical-case-reconciliation.json').read_text())
  self.assertEqual(len(expected['policy']),55);self.assertEqual(len(set(expected['integration'])),len(expected['integration']))
  self.assertEqual(reconciled['new_integration_cases'],expected['integration']);self.assertEqual(len(reconciled['previous_integration_cases']),64)
  self.assertEqual(set(reconciled['retained']),set(expected['integration']) & set(reconciled['previous_integration_cases']))
  self.assertEqual(set(reconciled['superseded']),set(reconciled['previous_integration_cases'])-set(reconciled['retained']))
  for old,item in reconciled['superseded'].items():
   self.assertTrue(item['reason']);self.assertTrue(item['covered_by']);self.assertTrue(set(item['covered_by']).issubset(expected['integration']))
  integration=(HERE/'IntegrationCases.swift').read_text()
  for key in ['device_executed','cms_verified','platform_tls_executed','portal_executed']:self.assertIn('"'+key+'":false',integration)
 def test_portal_lookup_is_strict_identity_bound_and_read_only(self):
  source=(ROOT/'SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift').read_text()
  helper=generator.extract(source,'private func fetchPreservingInstalledAuthorization()')
  self.assertIn('fetchAppIDsPreservingIdentity(for: team)',helper)
  self.assertNotIn('fetchAppIDs(for: team)',helper)
  self.assertIn('catch let error as AppIDLookupError',helper)
  self.assertIn('let matching = appIDs.filter { $0.bundleIdentifier == identity.resigned }',helper)
  self.assertIn('guard matching.count == 1, let existing = matching.first else',helper)
  self.assertLess(helper.index('guard matching.count == 1'),helper.index('candidateEvidence = try await operation.generateCandidate'))
  for forbidden in ['addAppID(', 'updateAppID(', 'deleteAppID(', 'updateFeatures(', 'updateAppGroups(']:self.assertNotIn(forbidden,helper)
  proxy=generator.extract((ROOT/'SideStore/Core/Auth/DeveloperPortalProxy.swift').read_text(),'    public func fetchAppIDsPreservingIdentity(')
  for required in ['getBoundSession()', 'getBoundTeam(team, context: context)', 'awaitBound(context)', 'fetchAppIDsPreservingIdentity(for: team, session: context.session)']:self.assertIn(required,proxy)
  self.assertNotIn('fetchAppIDs(for:',proxy)
  self.assertIn('lcPortalSigningRequest(sourceStep: "appIDLookup"',proxy)
  pipeline=(ROOT/'SideStore/Core/Operations/PipelineExecutor.swift').read_text()
  request=generator.extract(pipeline,'func lcPortalSigningRequest<T>(')
  self.assertNotIn('catch {',request)
  with tempfile.TemporaryDirectory() as directory:
   generator.generate(Path(directory));fixture=(Path(directory)/'Integration.swift').read_text()
   self.assertIn(request,fixture)
   self.assertIn('private final class LCSigningHTTPObservation:',fixture)
  failure=generator.extract(self.source(),'struct V3RefreshSelectionFailure:')
  for required in ['reason == .preservationPortalIdentityUnavailable, scope == .nonHost','detail.utf8.count <= 32','Self.portalIdentityKinds.contains(detail)']:self.assertIn(required,failure)
if __name__=='__main__':unittest.main()

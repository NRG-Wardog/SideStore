import pathlib, unittest, shutil, subprocess, tempfile, json, os
ROOT=pathlib.Path(__file__).resolve().parents[2]
def source(name): return (ROOT/name).read_text()
class Contract(unittest.TestCase):
 def test_actual_profile_selection(self):
  s=source('SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift')
  self.assertNotIn('profiles.values.first!',s)
  self.assertIn('profiles[self.context.targetBundleIdentifier]',s)
  self.assertIn('context.previouslyReusedExtensionIdentifiers.contains',s)
  self.assertLess(s.index('self.selectProfiles('),s.index('try await installProvisioningProfiles'))
  self.assertIn('$0.serialNumber == certificateSerial && $0.data == certificateData',s)
  doubles=source('tests/refresh_truth/operation_doubles.swift')
  self.assertIn('typealias NSManagedObjectContext = DatabaseContext',doubles)
  self.assertIn('var dbBackgroundContext: NSManagedObjectContext = DatabaseContext()',doubles)
  self.assertIn('let legacyReplacementBinding: V3LegacyReplacementBinding? = nil',doubles)
  self.assertIn('func validateLegacyReplacementAdmission() async throws',doubles)
  self.assertIn('func validateLegacyReplacementBundle(_ app: FixtureSignedBundle, signed: Bool) throws',doubles)
  for name in ['ALTApplication','ALTProvisioningProfile','ALTEntitlement','InstalledApp','InstalledExtension',
               'CertificateManager','InstallAppOperationContext','BasePipelineOperation','CellularRefreshManager',
               'PendingProfileBatch','V3RefreshFailureBoundary','OperationError']:
   self.assertRegex(doubles,r'(?:class|struct|enum) '+name+r'\b')
 def test_ack_before_bookkeeping(self):
  s=source('SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift')
  self.assertLess(s.index('context.recordRefreshVerification?(acknowledged)'),s.index('self.updateInstalledApp'))
  self.assertIn('before: before, after: after',s)
  group=source('SideStore/Core/Operations/RefreshGroup.swift')
  self.assertIn('lock.withLock { verificationByApp[bundleID]',group)
  self.assertIn('prior.mutationDispatched && !value.mutationDispatched',group)
  self.assertIn('prior.installAcknowledged && !value.installAcknowledged',group)
 def test_notification_not_optimistic(self):
  s=source('SideStore/Core/Operations/StandaloneOperations/BackgroundRefreshAppsOperation.swift')
  start=s.index('group.beginInstallationHandler')
  end=s.index('group.completionHandler',start)
  self.assertNotIn('.success(',s[start:end])
  self.assertNotIn('All apps have been refreshed.',s)
  self.assertEqual(s.count('row["verification"] = verification.wire'),2)
 def test_certificate_unknown_not_valid(self):
  s=source('SideStore/Core/Operations/PipelineOperations/VerifyCertificateOperation.swift')
  self.assertLess(s.index('if certificate.expiryDate <= Date()'),s.index('if portalCheck('))
  self.assertIn('throw OCSPValidationError.verificationUnavailable',s)
  self.assertNotIn('Assuming cross-signed',s)
  s=source('SideStore/Core/Certificates/OCSPValidator.swift')
  self.assertIn('case .unknown:\n            throw OCSPValidationError.verificationUnavailable',s)
 def test_owned_query_and_failure_evidence(self):
  s=source('SideStore/Core/Operations/PipelineRunner.swift')
  self.assertEqual(s.count('let result = try await transportCore.readInstalledProvisioningProfiles()'),2)
  self.assertEqual(s.count('try checkReadinessOwnership()\n                        return result'),2)
  self.assertIn('context.recordRefreshVerification = { group.setVerification',s)
 def test_shared_profile_evidence_sanitizer(self):
  def declaration(text, marker):
   start=text.index(marker); end=text.index('{',start)+1; depth=1
   while depth:
    depth+=(text[end]=='{')-(text[end]=='}');end+=1
   return text[start:end]
  host=pathlib.Path(os.environ.get('V3_HOST_SOURCE_ROOT', str(ROOT.parent/'LiveContainer')))
  peer=(host/'SideStoreSupport/SideStore.swift').read_text()
  producer=source('AltStore/AppDelegate.swift')
  for marker in ['public struct V3RefreshProfileEvidence {', 'public enum CombinedVerification {', 'public struct V3ProvisioningCauseDiagnostic {']:
   self.assertEqual(declaration(producer,marker),declaration(peer,marker))
  sanitizer=declaration(producer,'public enum CombinedVerification {')
  self.assertIn('hasCompleteTerminalResults(manifest, runID: runID)',sanitizer)
  self.assertIn('if let evidence = V3RefreshProfileEvidence(entry["verification"])',sanitizer)
  self.assertNotIn('host_profile_verification',sanitizer)
 def test_actual_swift_runtime(self):
  swift=shutil.which('swiftc')
  if not swift:
   if os.environ.get('V3_REQUIRE_SWIFT')=='1': self.fail('swiftc required')
   self.skipTest('swiftc unavailable; native qualification required')
  production=source('SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift')
  helper=production[production.index('struct V3RefreshVerification:'):production.index('// V3_PRESERVATION_PROFILE_AUTHORIZATION_V1')]
  fixture=source('tests/refresh_truth/runtime.swift')+'\n'+helper+'\n'+source('tests/refresh_truth/cases.swift')
  with tempfile.TemporaryDirectory(prefix='refresh-truth-') as temporary:
   root=pathlib.Path(temporary).resolve(); src=root/'Fixture.swift'; exe=root/'fixture'
   src.write_text(fixture)
   compiled=subprocess.run([swift,'-parse-as-library',str(src),'-o',str(exe)],timeout=120,capture_output=True,text=True)
   self.assertEqual(compiled.returncode,0,compiled.stdout+compiled.stderr)
   executed=subprocess.run([str(exe)],timeout=30,capture_output=True,text=True)
   self.assertEqual(executed.returncode,0,executed.stdout+executed.stderr)
   report=json.loads(executed.stdout)
   self.assertEqual(report['schema'],'refresh-truth-runtime-v1'); self.assertEqual(report['status'],'PASS')
   self.assertEqual(len(report['cases']),22); self.assertEqual(len(set(report['cases'])),22)
   print(json.dumps(report,sort_keys=True))
 def test_actual_operation_runtime(self):
  swift=shutil.which('swiftc')
  if not swift:
   if os.environ.get('V3_REQUIRE_SWIFT')=='1': self.fail('swiftc required')
   self.skipTest('swiftc unavailable; native qualification required')
  production=source('SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift')
  operation='\n'.join(line for line in production.splitlines() if not line.startswith('import '))
  def declaration(text, marker):
   start=text.index(marker); end=text.index('{',start)+1; depth=1
   while depth:
    depth+=(text[end]=='{')-(text[end]=='}');end+=1
   return text[start:end]
  replacementBinding=declaration(source('AltStore/AppDelegate.swift'),'struct V3LegacyReplacementBinding:')
  registry=declaration(source('SideStore/Core/Operations/OperationContexts.swift'),'enum V3ValidatedReuseMainRegistry {')
  policy=declaration(source('AltStore/AppDelegate.swift'),'enum V3MutationPersistencePolicy {')
  runner=source('SideStore/Core/Operations/PipelineRunner.swift')
  persistence=declaration(runner[runner.index('// V3_POST_MUTATION_PERSISTENCE_CONTRACT_V1:'):],'try await dbContext.perform {')
  glue='\nfunc actualRunnerPersistence(dbContext:DatabaseContext) async throws { let bundleID="synthetic";\n'+persistence+'\n}\n'
  groupSource=source('SideStore/Core/Operations/RefreshGroup.swift')
  group='\nfinal class EvidenceGroup { let lock=NSLock(); var verificationByApp:[String:V3RefreshVerification]=[:]\n'
  for signature in ['func setVerification(', 'func verification(for', 'func verificationSnapshot()']:
   group+=declaration(groupSource,signature)+'\n'
  group+='}\n'
  install=source('SideStore/Core/Operations/PipelineOperations/InstallAppOperation.swift')
  install=install[install.index('        // Read-only baseline on the same owned batch.'):install.index('        if !isDifferentSideStore && !isSelfReinstall && !isSideBackup {\n            // Capture what the signer actually installed, separately from the')]
  installGlue='\nextension InstallationHarness { func runInstall(resignedAppBundle:FixtureSignedBundle,certificate:FixtureSigningCertificate,isSelfReinstall:Bool=false,isSideBackup:Bool=false) async throws { let installedApp=context.dbBackgroundContext.app; let bundleID="synthetic";\n'+install+'\n} }\n'
  fixture=replacementBinding+'\n'+registry+'\n'+source('tests/refresh_truth/operation_doubles.swift')+'\n'+operation+'\n'+policy+glue+group+installGlue+source('tests/refresh_truth/operation_cases.swift')
  with tempfile.TemporaryDirectory(prefix='refresh-truth-operation-') as temporary:
   root=pathlib.Path(temporary).resolve(); src=root/'Fixture.swift'; exe=root/'fixture'
   src.write_text(fixture)
   result=subprocess.run([swift,'-parse-as-library',str(src),'-o',str(exe)],timeout=120,capture_output=True,text=True)
   self.assertEqual(result.returncode,0,result.stdout+result.stderr)
   result=subprocess.run([str(exe)],timeout=30,capture_output=True,text=True)
   self.assertLessEqual(len(result.stderr.encode()),32768,'Synthetic fixture diagnostics exceeded bound')
   self.assertEqual(result.returncode,0,result.stdout+result.stderr)
   for line in result.stderr.splitlines():
    observation=json.loads(line)
    self.assertIsInstance(observation,dict)
    self.assertTrue(set(observation).issubset({'fixture','ownerLookup','signedIDMatches','teamMatches',
      'parentURLMatches','parentPathMatches','certificateLookup','mutationCount'}))
    self.assertTrue(observation.get('fixture','').startswith('legacy-'))
    for key,value in observation.items():
     if key=='fixture': self.assertRegex(value,r'^legacy-[a-z-]{1,64}$')
     elif key=='mutationCount': self.assertTrue(type(value) is int and 0 <= value <= 2)
     else: self.assertIs(type(value),bool)
    print('SYNTHETIC_OPERATION_DIAGNOSTIC '+json.dumps(observation,sort_keys=True))
   report=json.loads(result.stdout)
   self.assertEqual(report['schema'],'refresh-truth-operation-v1');self.assertEqual(report['status'],'PASS')
   self.assertEqual(report['failed_cases'],[])
   self.assertEqual(len(report['cases']),62);self.assertEqual(len(set(report['cases'])),62)
   print(json.dumps(report,sort_keys=True))
if __name__=='__main__': unittest.main()

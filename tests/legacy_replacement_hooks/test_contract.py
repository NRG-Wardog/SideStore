from pathlib import Path
import unittest, os, shutil, subprocess, tempfile, json
ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
OPS=ROOT/'SideStore/Core/Operations'
def decl(s,marker):
 i=s.index(marker);j=s.index('{',i)+1;depth=1
 while depth: depth+=(s[j]=='{')-(s[j]=='}');j+=1
 return s[i:j]
def read(name): return (OPS/name).read_text()
class Hooks(unittest.TestCase):
 def test_owned_stage_and_keep_all(self):
  s=read('PipelineOperations/StageAppOperation.swift')
  part=decl(s,'        if let binding = context.legacyReplacementBinding {')
  self.assertLess(s.index(part),s.index('path.contains("SideBackup")'))
  self.assertLess(part.index('AppBundleFingerprint.compute(for: source.fileURL)'),part.index('computeOriginalCacheKey'))
  self.assertIn('AppBundleFingerprint.compute(for: destination) == binding.sourceTreeDigest',part)
  self.assertNotIn('hasPrefix',part)
  self.assertNotIn('removeItem',part)
  s=read('PipelineOperations/RemoveAppExtensionsOperation.swift')
  part=decl(s,'        if context.legacyReplacementBinding != nil {')
  self.assertLess(s.index(part),s.index('UserDefaults.standard.customizeAppExtensions'))
  self.assertIn('return targetAppBundle',part)
  self.assertNotIn('removeExtensions',part)
  self.assertNotIn('UserDefaults',part)
 def test_side_effect_admission_boundaries(self):
  s=read('PipelineOperations/ResignAppOperation.swift')
  body=decl(s,'    private func resignAppBundle(')
  self.assertLess(body.index('validateLegacyReplacementAdmission'),body.index('signer.signApp'))
  self.assertIn('legacyReplacementProfileKey(originalID: appExtension.bundleIdentifier)',s)
  s=read('PipelineOperations/SendAppOperation.swift')
  self.assertLess(s.index('turnOffDataIfNeeded'),s.rindex('validateLegacyReplacementAdmission'))
  self.assertLess(s.rindex('validateLegacyReplacementAdmission'),s.index('try await sendIpaAfc'))
  s=read('PipelineOperations/InstallAppOperation.swift')
  before=s[s.index('let beforeProfiles ='):s.index('let dispatched =')]
  self.assertIn('try await context.validateLegacyReplacementAdmission()',before)
  self.assertIn('validateLegacyReplacementBundle(resignedAppBundle, signed: true)',before)
  after=s[s.index('// Native install acknowledged.'):]
  self.assertNotIn('validateLegacyReplacementAdmission',after)
  save=decl(after[after.index('// V3_LEGACY_REPLACEMENT_POST_ACK_SAVE_V1:'):],'        if context.legacyReplacementBinding != nil {')
  self.assertIn('V3MutationPersistencePolicy.persistResult',save)
  self.assertNotIn('refreshVerification',save)
  self.assertNotIn('Task.checkCancellation',save)
 def test_exact_profile_and_certificate(self):
  s=read('PipelineOperations/FetchProvisioningProfilesOperation.swift')
  self.assertIn('self.context.validateExtensionSigningCapabilities = self.context.validatedReuseMain || self.context.legacyReplacementBinding != nil',s)
  self.assertIn('binding.extensionIdentities[targetAppBundle.bundleIdentifier]',s)
  self.assertIn('profile.bundleIdentifier == bundleID',s)
  self.assertIn('missing.count <= max(0, Team.maximumFreeAppIDs - appIDs.count)',s)
  s=read('PipelineRunner.swift')
  part=decl(s,'        if let binding = handler.legacyReplacementBinding {')
  for item in ['guard case .resign = operation','certificate.serialNumber == binding.certificateSerial','certificate.x509.data == binding.certificateDER','context.useMainProfile = false','context.overrideProvisioningProfile = nil']:
   self.assertIn(item,part)
  s=read('PipelineOperations/UpdateAppCertificateOperation.swift')
  self.assertLess(s.index('if context.legacyReplacementBinding != nil'),s.index('ProfileManager.shared.getAssignedProfile'))
 def test_native_actual_context_hooks(self):
  compiler=shutil.which('swiftc')
  if not compiler:
   if os.environ.get('V3_REQUIRE_SWIFT')=='1':self.fail('swiftc required')
   self.skipTest('native Swift qualification required')
  source=read('OperationContexts.swift')
  binding=decl((ROOT/'AltStore/AppDelegate.swift').read_text(),'struct V3LegacyReplacementBinding:')
  methods='\n'.join(decl(source,m) for m in ['    func validateLegacyReplacementAdmission()', '    func validateLegacyReplacementBundle(', '    func legacyReplacementProfileKey(', '    func validateLegacyReplacementProfiles('])
  stage=decl(read('PipelineOperations/StageAppOperation.swift'),'        if let binding = context.legacyReplacementBinding {')
  removal=decl(read('PipelineOperations/RemoveAppExtensionsOperation.swift'),'        if context.legacyReplacementBinding != nil {')
  actual='\nfinal class FixtureOperations { let context:FixtureContext; init(_ c:FixtureContext){context=c};func setProgress(_ value:Int){}\nfunc stage() async throws -> ALTApplication {\n'+stage+'\nfatalError("binding required")}\nfunc keepAll(_ targetAppBundle:ALTApplication) async throws -> ALTApplication {\n'+removal+'\nfatalError("binding required")}\n}\n'
  install=read('PipelineOperations/InstallAppOperation.swift')
  save=decl(install[install.index('// V3_LEGACY_REPLACEMENT_POST_ACK_SAVE_V1:'):],'        if context.legacyReplacementBinding != nil {')
  app=(ROOT/'AltStore/AppDelegate.swift').read_text()
  persistence='struct CombinedFailure {\n'+decl(app,'    public enum Stage:')+'\n'+decl(app,'    public enum SafeCause:')+'\n}\n'+decl(app,'struct V3PostMutationPersistenceError:')+'\n'+decl(app,'enum V3MutationPersistencePolicy {')
  actual+='\nfunc actualPostAcknowledgementSave(context:FixtureContext,backgroundContext:FixtureDB) async throws {\n'+save+'\n}\n'+persistence
  fetch=read('PipelineOperations/FetchProvisioningProfilesOperation.swift')
  flag=next(line.strip() for line in fetch.splitlines() if line.strip().startswith('self.context.validateExtensionSigningCapabilities ='))
  resign=decl(read('PipelineOperations/ResignAppOperation.swift'),'    private func resignAppBundle(')
  branches=resign[resign.index('        if context.useMainProfile'):resign.index('        return fileURL')]
  policy=(ROOT/'Dependencies/SideSign/Sources/CodeSigning/ExtensionSigningPolicy.swift').read_text()
  signer=(ROOT/'Dependencies/SideSign/Sources/CodeSigning/CodeSignerAPI.swift').read_text()
  guard=decl(signer,'            if extensionStrategy != .perExtension,')
  actual+='\nfinal class StrategyOperation { let context:FixtureContext;init(_ c:FixtureContext){context=c};func fetchFlag(){'+flag+'};func sign(_ signer:StrategySigner) async throws {let fileURL=URL(fileURLWithPath:"/synthetic");let profiles:[ALTProvisioningProfile]=[]\n'+branches+'\n}}\n'
  actual+='\nfunc actualSignerCapabilityGuard(extensionStrategy:ExtensionSigningStrategy,app:StrategyApp,matchedProfile:StrategyProfile,filteredEntitlements:[String:any Sendable]) throws {\n'+guard+'\n}\n'+policy
  fingerprint=(ROOT/'SideStore/Utils/common/AppBundleFingerprint.swift').read_text()
  fixture=(HERE/'doubles.swift').read_text()+binding+'\nextension FixtureContext {\n'+methods+'\n}\n'+fingerprint+actual+(HERE/'cases.swift').read_text()
  with tempfile.TemporaryDirectory() as d:
   path=Path(d).resolve();f=path/'Fixture.swift';f.write_text(fixture);exe=path/'fixture'
   result=subprocess.run([compiler,'-parse-as-library',str(f),'-o',str(exe)],capture_output=True,text=True,timeout=120)
   self.assertEqual(result.returncode,0,result.stdout+result.stderr)
   result=subprocess.run([str(exe)],capture_output=True,text=True,timeout=30)
   self.assertEqual(result.returncode,0,result.stdout+result.stderr)
   report=json.loads(result.stdout);self.assertEqual(report['status'],'PASS');self.assertEqual(len(report['cases']),35)
   print(json.dumps(report,sort_keys=True))
if __name__=='__main__':unittest.main()

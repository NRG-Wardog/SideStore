#!/usr/bin/env python3
import argparse, hashlib, importlib.util, json, re, subprocess, sys, tempfile, unittest
from pathlib import Path
HERE=Path(__file__).resolve().parent
SPEC=importlib.util.spec_from_file_location('fixture',HERE/'generate.py'); G=importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(G)
ROOT=HERE.parents[2]
class DeferredSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ss=ROOT/'SideStore'; cls.lc=ROOT/'LiveContainer'
        cls.op=(cls.ss/'SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift').read_text()
        cls.service=(cls.ss/'AltStore/AppDelegate.swift').read_text()
        cls.ui=(cls.lc/'LiveContainerSwiftUI/Views/V3UnifiedShell.swift').read_text()
        cls.pair=(cls.ss/'SideStore/Core/Pairing/PairingFileManager.swift').read_text()
        cls.keychain=(cls.ss/'AltStore/Core/Components/Keychain.swift').read_text()
    def test_source_generation_identity_and_closure(self):
        with tempfile.TemporaryDirectory() as d:
            subprocess.run([sys.executable,str(HERE/'generate.py'),'--sources',str(ROOT),'--output-dir',d],check=True)
            out=Path(d); evidence=json.loads((out/'source-evidence.json').read_text())
            self.assertFalse(evidence['network']); self.assertFalse(evidence['native_provider']); self.assertFalse(evidence['swift_executed'])
            for name,digest in evidence['outputs'].items(): self.assertEqual(hashlib.sha256((out/name).read_bytes()).hexdigest(),digest)
            generated=(out/'CandidateDeferredSetup.swift').read_text()
            for a in ['private func performProvisioningLoop(', 'private func performFinalizeAuthentication(', 'private func v3ValidateDeferredIdentity(']: self.assertIn(G.block(self.op,a),generated)
            self.assertIn(G.block(self.pair,'nonisolated var v3DeviceSetupIsUnconfigured: Bool {'),generated)
            self.assertIn(G.block(self.keychain,'enum V3PendingCertificateKeyProof {'),generated)
            self.assertIn(G.block(self.service,'if operation.v3DidDeferDeviceSetup {'),generated)
            start=self.service.index('        case "certExportActive":\n')+len('        case "certExportActive":\n')
            end=self.service.index('        case "certSetActive":',start)
            self.assertIn(self.service[start:end],generated)
            doubles=(out/'BoundaryDoubles.swift').read_text()
            required=set(re.findall(r'\b(V3Remote\w+)\b',generated))
            declared=set(re.findall(r'(?:struct|enum|class) (V3Remote\w+)',doubles))
            self.assertLessEqual(required,declared)
            boundary=G.block(doubles,'enum V3RemoteIdentityContinuity {')
            calls=set(re.findall(r'V3RemoteIdentityContinuity\.(\w+)',generated))
            methods=set(re.findall(r'static func (\w+)',boundary))
            self.assertLessEqual(calls,methods)
            self.assertIn('guard handoff == nil else { throw V3RemoteIdentityError.stateChanged }',boundary)
    def test_deferral_is_before_registration_after_certificates(self):
        p=G.block(self.op,'private func performProvisioningLoop(')
        self.assertLess(p.index('isCertificateResolved = true'),p.index('V3DeviceSetupDeferralPolicy.mayDefer'))
        self.assertLess(p.index('V3DeviceSetupDeferralPolicy.mayDefer'),p.index('self.registerCurrentDevice('))
        self.assertIn('self.v3DidCompleteProvisioning = false',p)
        self.assertNotIn('v3DidDeferDeviceSetup',p[p.index('} catch {'):])
    def test_checked_activation_and_postauth_order(self):
        p=G.block(self.op,'private func performFinalizeAuthentication(')
        self.assertEqual(p.count('v3ValidateDeferredIdentity(result, capturedStamp: deferredIdentityStamp)'),2)
        self.assertLess(p.index('v3ValidateDeferredIdentity'),p.index('saveTeamAndAccount(team, makeActive: true)'))
        self.assertLess(p.index('saveTeamAndAccount(team, makeActive: true)'),p.rindex('v3ValidateDeferredIdentity'))
        self.assertLess(p.rindex('v3ValidateDeferredIdentity'),p.index('var didResign'))
        self.assertIn('await self.signInHandler.complete() }\n                    return',p)
        transaction=G.block(self.op,'private func performSaveTeamAndAccount(')
        for gate in ['try context.save()', 'guard observed == intended', 'try V3AccountDatabaseRecovery.reconcile(observed: observed)']: self.assertIn(gate,transaction)
    def test_identity_proof_remains_strict(self):
        p=G.block(self.op,'private func v3ValidateDeferredIdentity(')
        for gate in ['!Task.isCancelled', 'v3CachedSessionMatchesCurrentRoute', 'account.identifier == result.session.dsid', 'mayUseTeam', 'organizationalUnit == result.team.identifier', 'V3PendingCertificateKeyProof.matches', 'active.certificate.x509.data == der']: self.assertIn(gate,p)
        self.assertIn('privateKeyPEM: active.certificate.privateKey) ||',p)
        self.assertIn('privateKeyDER: active.certificate.privateKey)',p)
    def test_no_absence_inference_from_read_failure(self):
        p=G.block(self.pair,'nonisolated var v3DeviceSetupIsUnconfigured: Bool {')
        self.assertIn('if UserDefaults.standard.isPairingReset { return true }',p)
        self.assertNotIn('fetchPairingFile(',p); self.assertNotIn('fileExists(',p); self.assertNotIn('try?',p)
        self.assertIn('NSFileReadNoSuchFileError',p); self.assertIn('contents == "<insert pairing file here>"',p)
    def test_service_deferral_never_completes_journal(self):
        p=G.block(self.service,'if operation.v3DidDeferDeviceSetup {')
        self.assertNotIn('provisioningCompletion.complete(',p)
        self.assertIn('!operation.v3DidCompleteProvisioning',p)
        for gate in ['ownsActiveSession(id)', '!Task.isCancelled', 'activeAccount?.identifier == account.identifier', 'activeTeam?.account?.identifier == activeAccount?.identifier', 'certificate.x509.data == activeCertificate.x509.data']: self.assertIn(gate,p)
        self.assertIn('"outcome": "setupDeferred"',p); self.assertIn('"setupDeferredReason": "pairingUnconfigured"',p)
        self.assertNotIn('"state": "completed"',p)
    def test_host_shows_pending_not_failure_for_allowlisted_outcome(self):
        self.assertIn('if !deviceSetupDeferred {\n                let diagnosticPresentation',self.ui)
        self.assertIn('Button(auth.deviceSetupDeferred ? "Done" : "Finish Later")',self.ui)
        self.assertIn('deviceSetupDeferred = false\n        provisioningIncomplete = false',self.ui)
        for owner in [self.service, (self.lc/'SideStoreSupport/SideStore.swift').read_text(), self.ui]:
            self.assertEqual(G.block(self.service,'enum V3DeviceSetupDeferralPolicy {'),G.block(owner,'enum V3DeviceSetupDeferralPolicy {'))
    def test_frozen_cases_and_no_native_io_in_doubles(self):
        runtime=(HERE/'RuntimeTests.swift').read_text(); doubles=(HERE/'BoundaryDoubles.swift').read_text()
        for case in G.CASE_NAMES: self.assertEqual(runtime.count('cases.append("'+case+'")'),1)
        self.assertEqual(len(G.CASE_NAMES),len(set(G.CASE_NAMES)))
        for forbidden in ['URLSession', 'SecItemAdd', 'SecItemCopyMatching', 'minimuxer', 'Data(contentsOf:', 'Boundary.keyMatches', 'enum V3PendingCertificateKeyProof']: self.assertNotIn(forbidden,doubles)
        self.assertIn('SecKeyCreateRandomKey',doubles)
        self.assertIn('kSecAttrIsPermanent as String: false',doubles)
        self.assertIn('SecKeyCreateSignature',doubles)
        self.assertIn('DEFERRED_PRIOR_PEM_REJECTION_REPRODUCED',runtime)
        self.assertIn('DEFERRED_DEVICE_SETUP_FIXTURE_PASS',runtime)
if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--sources',type=Path); a,rest=parser.parse_known_args()
    if a.sources: ROOT=a.sources
    unittest.main(argv=[sys.argv[0]]+rest)

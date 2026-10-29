from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/'AltStore/AppDelegate.swift'
def extract(text, marker):
    start=text.index(marker); brace=text.index('{',start); depth=0
    for i in range(brace,len(text)):
        if text[i]=='{': depth+=1
        elif text[i]=='}':
            depth-=1
            if depth==0:return text[start:i+1]
    raise AssertionError('unbalanced source')
class DirectEvidence(unittest.TestCase):
    def test_registration_precedes_synchronous_callback(self):
        s=extract(SOURCE.read_text(),'    private func single(id: String, operation: AppOperation')
        self.assertLess(s.index('session.group = group'),s.index('performSingleOperation('))
        self.assertLess(s.index('sessions[id] = session'),s.index('performSingleOperation('))
        self.assertIn('suppliedGroup: group',s)
        self.assertIn('undispatched.mutationDispatched = false',s)
    def test_terminal_is_qualified_before_store_and_journal_preserves_unknown(self):
        s=SOURCE.read_text(); driver=extract(s,'    private func drive(id: String, driver: V3OpDriver')
        self.assertIn('verificationSnapshot().values.map { $0.wire }',driver)
        self.assertIn('finish(id: id, response: qualifiedTerminal)',driver)
        journal=extract(s,'    private func settleOperationRecoveryIfTerminal(')
        self.assertIn('!outcomeUnknown',journal)
    @unittest.skipUnless(shutil.which('swiftc'),'native Swift qualification required in CI')
    def test_actual_policy(self):
        source='import Foundation\nimport CoreFoundation\n'+'''enum V3WireContract {
 static func strictBool(_ value: Any?) -> Bool? {
 guard let n=value as? NSNumber, CFGetTypeID(n)==CFBooleanGetTypeID() else{return nil};return n.boolValue
 }
}\n'''+extract(SOURCE.read_text(),'enum V3DirectInstallEvidencePolicy {')+'\n'+(Path(__file__).with_name('cases.swift')).read_text()
        with tempfile.TemporaryDirectory() as d:
            p=Path(d).resolve();(p/'main.swift').write_text(source)
            subprocess.run(['swiftc',str(p/'main.swift'),'-o',str(p/'fixture')],check=True,capture_output=True,text=True,timeout=90)
            r=subprocess.run([str(p/'fixture')],check=True,capture_output=True,text=True,timeout=20)
            self.assertIn('DIRECT_REFRESH_EVIDENCE_PASS cases=14',r.stdout)
    @unittest.skipUnless(shutil.which('swiftc'),'native Swift qualification required in CI')
    def test_actual_single_registration(self):
        method=extract(SOURCE.read_text(),'    private func single(id: String, operation: AppOperation')
        source=Path(__file__).with_name('registration.swift').read_text().replace('// ACTUAL_SINGLE',method)
        with tempfile.TemporaryDirectory() as d:
            p=Path(d).resolve();(p/'fixture.swift').write_text(source)
            subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p/'fixture.swift'),'-o',str(p/'fixture')],check=True,capture_output=True,text=True,timeout=90)
            r=subprocess.run([str(p/'fixture')],check=True,capture_output=True,text=True,timeout=20)
            self.assertIn('DIRECT_REGISTRATION_PASS cases=3',r.stdout)
if __name__=='__main__':unittest.main()

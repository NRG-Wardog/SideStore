"""Diagnostic branch only. Read maintained sources; no patcher or parity bypass."""
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
PEER = Path(os.environ['ADI_CONSUMPTION_PEER_ROOT']) if os.environ.get('ADI_CONSUMPTION_PEER_ROOT') else None
PRODUCER = Path(os.environ['ADI_CONSUMPTION_PRODUCER_ROOT']) if os.environ.get('ADI_CONSUMPTION_PRODUCER_ROOT') else None
SWIFTC = shutil.which('swiftc')
def owner(root):
    return root / ('AltStore/AppDelegate.swift' if (root/'AltStore').exists() else 'SideStoreSupport/SideStore.swift')
def declaration(s, signature):
    start=s.index(signature); opening=s.index('{',start); depth=1; end=opening+1
    while depth:
        depth+=(s[end]=='{')-(s[end]=='}');end+=1
    return s[start:end]
def common(s):
    start=s.index('public struct CombinedRefreshTargetPlan:')
    end=declaration(s,'public enum V3DiagnosticPresentation {')
    return 'import Foundation\nimport CoreFoundation\n'+s[start:s.index(end,start)+len(end)]
def ss_root(): return ROOT if (ROOT/'AltStore').exists() else PEER
def lc_root(): return ROOT if (ROOT/'SideStoreSupport').exists() else PEER

class ConsumerContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app=owner(ROOT).read_text()
        cls.schema=json.loads((ROOT/'docs/debug-adi-consumption/contract-v2.json').read_text())

    def test_shared_parser_and_schema_are_exact_across_owners(self):
        if PEER is None: self.skipTest('Provide the independently owned peer source root')
        peer=owner(PEER).read_text()
        for signature in ['public struct V3TemporaryADIConsumption {','public struct V3TemporaryAnisetteTrace:', 'struct V3AnisetteNativeEvidence {']:
            self.assertEqual(declaration(self.app,signature),declaration(peer,signature))
        self.assertEqual(self.schema,json.loads((PEER/'docs/debug-adi-consumption/contract-v2.json').read_text()))
        view=(lc_root()/'LiveContainerSwiftUI/Views/V3UnifiedShell.swift').read_text()
        self.assertIn('import SideStoreSupport',view)
        self.assertIn('V3TemporaryADIConsumption.init(encoded:)',declaration(view,'enum V3AuthFailureDiagnosticsPolicy {'))

    def test_wire_and_render_use_real_finite_contract(self):
        text=self.app
        self.assertEqual(text.count('public struct V3TemporaryADIConsumption {'),1)
        self.assertIn('return V3TemporaryADIConsumption.boundingWire(result)',declaration(text,'    public var wire:'))
        validate=declaration(text,'    public static func validatedSigningContext(')
        self.assertIn('V3TemporaryADIConsumption.sanitizingContext(value)',validate)
        native=declaration(text,'struct V3AnisetteNativeEvidence {')
        self.assertLess(native.index('splitDescription(description)'),native.index('captureBase(code: code'))
        trace=declaration(text,'public struct V3TemporaryAnisetteTrace:')
        self.assertIn('V3TemporaryADIConsumption.splitDescription(description).base',trace)
        helper=declaration(text,'public struct V3TemporaryADIConsumption {')
        for forbidden in ['print(', 'UserDefaults', 'FileManager', '@TaskLocal','static var']:
            self.assertNotIn(forbidden,helper)
        self.assertIn('DEBUG TEMPORARY adi_consumption=',helper)
        self.assertIn('rows.dropFirst()',helper)
        self.assertIn('result["signingContext"] = context',helper)
        self.assertIn('(0...4).contains(fields[2])',helper)

    def produced(self):
        if PRODUCER is None: self.skipTest('Provide maintained Anisette observer source root')
        header=PRODUCER/'Native/Loader/adi_consumption_debug.h'
        self.assertEqual(hashlib.sha256(header.read_bytes()).hexdigest(),self.schema['producer_header_sha256'])
        self.assertEqual(hashlib.sha256((PRODUCER/'Sources/AnisetteDataProvider.swift').read_bytes()).hexdigest(),self.schema['producer_swift_sha256'])
        sdk=(PRODUCER/'Sources/AnisetteDataProvider.swift').read_text()
        for text in [declaration(self.app,'public struct V3TemporaryADIConsumption {'),
                     declaration(sdk,'private enum TemporaryADIConsumptionTrace {')]:
            ranges={int(index):[int(low),int(high.replace('_',''))] for low,high,index in
                    re.findall(r'\((-?\d+)\.\.\.([\d_]+)\)\.contains\(fields\[(\d)\]\)',text)}
            self.assertEqual([ranges[i] for i in range(8)],self.schema['ranges'])
        self.assertIn('limit = 32, countLimit = 1048576',header.read_text())
        self.assertIn('char encoded[2048]',header.read_text())
        self.assertIn('enum Target { Other, ExpectedBlob, Relative, Unreadable, Untracked }',header.read_text())
        helper=declaration(self.app,'public struct V3TemporaryADIConsumption {')
        for name,value in [('maximumBytes',2048),('maximumEvents',32),('maximumWireBytes',4096)]:
            self.assertIn('public static let '+name+' = '+str(value),helper)
        compiler=shutil.which('c++')
        if not compiler:self.skipTest('C++ compiler unavailable')
        with tempfile.TemporaryDirectory() as directory:
            d=Path(directory);(d/'main.cpp').write_text('''#include "adi_consumption_debug.h"
#include <cstdio>
int main(){uint8_t id[16]={};const uint8_t input[]={1,2,3,4};ADIConsumptionDebug t("/SECRET_PATH",id,input,4);t.phase=ADIConsumptionDebug::OTP;
t.track(10,ADIConsumptionDebug::ExpectedBlob);
t.record(ADIConsumptionDebug::Open,ADIConsumptionDebug::ExpectedBlob,1,0);
t.observeRead(10,input,4,0);
t.record(ADIConsumptionDebug::Read,ADIConsumptionDebug::ExpectedBlob,1,0,4,4,0);
char *out=strdup("{\\"error\\":\\"synthetic\\"}");t.append(&out);puts(out);free(out);}
''')
            subprocess.run([compiler,'-std=c++17','-I',str(header.parent),str(d/'main.cpp'),'-o',str(d/'producer')],check=True,capture_output=True,timeout=60)
            value=json.loads(subprocess.check_output([str(d/'producer')],text=True,timeout=10))['v3_native_consumption']
        self.assertEqual(value,'v2|0|1|1|5,0,1,1,0,0,0,-1|5,1,1,1,0,4,4,0')
        self.assertNotIn('SECRET',value)
        return value

    def test_real_cpp_producer_descriptor_and_pinned_schema(self): self.produced()

    def swift_sources(self):
        if PEER is None:self.skipTest('Peer owner source required')
        ss=owner(ss_root()).read_text()
        classifier=ss[ss.index('enum V3AuthFailureKind:'):ss.index('// MARK: - Provisioning failure guidance')]
        sdk=(PRODUCER/'Sources/AnisetteDataProvider.swift').read_text()
        return common(self.app)+'\n'+classifier+'\n'+(ROOT/'tests/adi_consumption/external_error_doubles.swift').read_text()+'\n'+declaration(sdk,'private enum TemporaryADIConsumptionTrace {')

    def execute(self,disabled=False):
        produced=self.produced()
        if not SWIFTC:self.skipTest('Swift compiler unavailable; native decoder/pipeline not executed')
        source=self.swift_sources()
        if disabled:source=source.replace('public static let temporaryAnisetteTraceEnabled = true','public static let temporaryAnisetteTraceEnabled = false')
        harness=(ROOT/'tests/adi_consumption/pipeline_harness.swift').read_text()
        with tempfile.TemporaryDirectory() as directory:
            d=Path(directory);(d/'main.swift').write_text(source+'\n'+harness)
            built=subprocess.run([SWIFTC,'-parse-as-library',str(d/'main.swift'),'-o',str(d/'test')],capture_output=True,text=True,timeout=180)
            self.assertEqual(built.returncode,0,built.stderr)
            run=subprocess.run([str(d/'test'),produced,'disabled' if disabled else 'enabled',str(d/'failure.txt')],capture_output=True,text=True,timeout=30)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn('ADI_CONSUMER_PIPELINE_PASS',run.stdout)
            if not disabled:self.host_roundtrip(d,d/'failure.txt')

    def host_roundtrip(self,d,failure):
        support=owner(lc_root()).read_text();view=(lc_root()/'LiveContainerSwiftUI/Views/V3UnifiedShell.swift').read_text()
        (d/'Support.swift').write_text(common(support))
        library=d/('libSideStoreSupport.dylib' if sys.platform=='darwin' else 'libSideStoreSupport.so')
        built=subprocess.run([SWIFTC,'-emit-library','-emit-module','-module-name','SideStoreSupport',str(d/'Support.swift'),'-emit-module-path',str(d/'SideStoreSupport.swiftmodule'),'-o',str(library)],capture_output=True,text=True,timeout=180)
        self.assertEqual(built.returncode,0,built.stderr)
        (d/'Host.swift').write_text('import Foundation\nimport SideStoreSupport\n'+declaration(view,'enum V3AuthFailureDiagnosticsPolicy {')+'''\nlet text=try String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8)
let id="00000000-0000-0000-0000-000000000001"
let failure=CombinedFailure.fromEncodedString(text,expectedID:id)!
var wire=failure.wire;wire["kind"]="anisette"
let rendered=V3AuthFailureDiagnosticsPolicy.render(wire,underlyingCode:0,retryableValue:nil)
precondition(rendered.contains("DEBUG TEMPORARY adi_consumption=v2|"))
precondition(rendered.contains("native_phase=nativeOTP"))
precondition(!rendered.contains("SECRET"))
print("HOST_CONSUMER_PASS")
''')
        built=subprocess.run([SWIFTC,'-I',str(d),'-L',str(d),'-lSideStoreSupport',str(d/'Host.swift'),'-o',str(d/'host')],capture_output=True,text=True,timeout=180)
        self.assertEqual(built.returncode,0,built.stderr)
        env=dict(os.environ);env['DYLD_LIBRARY_PATH' if sys.platform=='darwin' else 'LD_LIBRARY_PATH']=str(d)
        run=subprocess.run([str(d/'host'),str(failure)],env=env,capture_output=True,text=True,timeout=30)
        self.assertEqual(run.returncode,0,run.stderr);self.assertIn('HOST_CONSUMER_PASS',run.stdout)

    def test_legacy_comparison_is_read_only_snapshot_bound_and_failure_scoped(self):
        if ss_root() is None: self.skipTest('SideStore owner source required')
        keychain=(ss_root()/'AltStore/Core/Components/Keychain.swift').read_text()
        method=declaration(keychain,'    static func observeLegacyAnisetteComparison(')
        self.assertEqual(method.count('LCAnisetteStoredPair.read'),2)
        self.assertEqual(method.count('legacyAnisetteItems()'),1)
        self.assertIn('withSharedTransaction',method)
        for forbidden in ['.set(', 'writeOne(', 'remove', 'delete', 'reconcile', 'resolveAnisetteSnapshot']:
            self.assertNotIn(forbidden,method)
        manager=(ss_root()/'SideStore/Core/Anisette/OnDeviceAnisetteManager.swift').read_text()
        observation=manager[manager.index('// DEBUG TEMPORARY: inspect only already-entitled'):manager.index('        guard LCAnisetteRecoveryPolicy.automaticRecoveryEnabled else {')]
        for required in ['temporaryAnisetteTraceEnabled','code == -45061','snapshot.adiBlob != nil','.phase == .nativeOTP','observeLegacyAnisetteComparison(snapshot)','comparison = .unavailable','Task.checkCancellation()']:
            self.assertIn(required,observation)
        for forbidden in ['commitAnisette','anisetteRecoveryCandidate','IsolatedProbe','set(', 'resolveAnisetteSnapshot']:
            self.assertNotIn(forbidden,observation)
        if not SWIFTC: self.skipTest('Swift compiler unavailable; actual read-only wrapper not executed')
        types='\n'.join(declaration(keychain,signature) for signature in [
            'struct LCAnisetteStoredPair:', 'struct LCEmbeddedAnisetteSnapshot:',
            'struct LCLegacyKeychainItem {', 'struct LCAnisetteLegacyComparison:'])
        harness=(ROOT/'tests/adi_consumption/legacy_comparison_harness.swift').read_text()
        source=harness.replace('// ACTUAL_TYPES',types).replace('// ACTUAL_WRAPPER',method)
        with tempfile.TemporaryDirectory() as directory:
            d=Path(directory);(d/'main.swift').write_text(source)
            build=subprocess.run([SWIFTC,'-parse-as-library',str(d/'main.swift'),'-o',str(d/'test')],capture_output=True,text=True,timeout=180)
            self.assertEqual(build.returncode,0,build.stderr)
            result=subprocess.run([str(d/'test')],capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('LEGACY_COMPARISON_READ_ONLY_PASS',result.stdout)

    def test_native_pipeline_wire_copy_and_importing_host(self):self.execute()
    def test_disabled_trace_preserves_classification_and_drops_diagnostics(self):self.execute(True)

if __name__=='__main__':unittest.main(verbosity=2)

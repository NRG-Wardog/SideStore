import base64,json,pathlib,unittest,importlib.util,re
HERE=pathlib.Path(__file__).resolve().parent
ROOT=HERE.parents[1]
class Contract(unittest.TestCase):
 def test_synthetic_identity_closure(self):
  f=json.loads((HERE/'swift-cases.json').read_text());self.assertEqual(f['schema'],'scratch-parser-only-v1')
  cases=f['cases'];self.assertEqual(len(cases),45);self.assertEqual(len({c['name'] for c in cases}),45)
  self.assertEqual(sum(c['accept'] for c in cases),19)
  expected=json.loads((HERE/'expected-cases.json').read_text())
  self.assertEqual([c['name'] for c in cases],expected['parser']);self.assertEqual(len(expected['public']),16)
  for c in cases:
   self.assertIs(type(c['accept']),bool)
   for k in ['outer','inner']:self.assertTrue(base64.b64decode(c[k],validate=True))
 def test_exact_product_source_compiled(self):
  s=(HERE/'run.sh').read_text()
  self.assertIn('cat SideStore/Core/Operations/PipelineOperations/PreservedProfileDecoder.swift tests/preservation_der/SwiftCases.swift',s)
  self.assertIn('swiftc "$work/main.swift"',s)
  self.assertIn("r['cms_verified'] is False",s)
  self.assertIn('primary_status=$?',s)
  self.assertIn('exit "$primary_status"',s)
  self.assertLess(s.index('exit "$primary_status"'),s.index("python3 - "))
  spec=importlib.util.spec_from_file_location('failure_diagnostic',HERE/'generate_failure_diagnostic.py')
  module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
  source=(ROOT/'SideStore/Core/Operations/PipelineOperations/PreservedProfileDecoder.swift').read_text()
  generated=module.instrument(source)
  restored=generated.split('\n',1)[1].split('\n#sourceLocation()\n',1)[0]
  restored=restored.replace('_ condition: Bool, sourceLine: Int = #line)', '_ condition: Bool)')
  restored=restored.replace('_ parser: XMLParser, sourceLine: Int = #line)', '_ parser: XMLParser)')
  restored=restored.replace('diagnosticLog("callback line=\\(sourceLine)"); ', '')
  restored=re.sub(r'throw diagnosticFailure\(\.(malformed|unsupported|inconsistent), line: (sourceLine|[0-9]+)\)',r'throw Failure.\1',restored)
  self.assertEqual(restored,source.rstrip('\n'))
  self.assertIn('guard count < 12 else { return }',module.HELPERS)
  self.assertIn('return reason',module.HELPERS)
  self.assertNotIn('localizedDescription',module.MAIN)

 def test_strict_boundaries_remain(self):
  s=(ROOT/'SideStore/Core/Operations/PipelineOperations/PreservedProfileDecoder.swift').read_text()
  for t in ['static func decodeOuter(verifiedOuterXML:', 'parser.externalEntityResolvingPolicy = .never', 'rawInner: verifiedInnerDER', 'Set<String> = ["UUID","CreationDate","ExpirationDate"]', 'pair.raw', 'a.utf8.elementsEqual(b.utf8)', 'CFBooleanGetTypeID()']:
   self.assertIn(t,s)
  self.assertIn('node.text.unicodeScalars.filter',s)
  self.assertIn('[UInt32(0x20), 0x09, 0x0D, 0x0A]',s)
  self.assertNotIn('ignoreUnknownCharacters',s)
 def test_public_actual_source_and_version_closure(self):
  s=(HERE/'run_public.sh').read_text()
  for token in ['"$core/profile_cms.c"','"$mini/DeviceGateway/libimobiledevice/ProvisioningCMSVerifier.swift"','"$mini/Sources/ProfileCMSVerifier.swift"','OPENSSL_VERSION_PATCH==9','"$work/version"',"trap 'rm -rf \"$work\"' EXIT",'"$work/public-inputs"']:
   self.assertIn(token,s)
  self.assertNotIn('-DV3_CMS_TESTING',s)
  f=(HERE/'PublicCases.swift').read_text()
  for token in ['ProfileCMSVerifier.authenticateOuter(cms)','ProfileCMSVerifier.authenticateInner(nested)','PreservedProfileDecoder.decode(verifiedOuterXML: outer, verifiedInnerDER: inner)','cases.count == 16','cross-profile-binding-rejected']:
   self.assertIn(token,f)
 def test_public_manifest_bounded_data_only(self):
  m=json.loads((HERE/'public-fixtures.json').read_text());self.assertEqual(m['schema'],'preservation-der-public-fixtures-v1')
  self.assertEqual(len(m['fixtures']),2)
  for f in m['fixtures']:
   self.assertTrue(f['url'].startswith('https://raw.githubusercontent.com/dotnet/macios/410dc42e09f1bfca3258d46d5ec95cf48903d1b2/tests/msbuild/Xamarin.MacDev.Tasks.Tests/Resources/'))
   self.assertEqual(len(f['sha256']),64);self.assertLess(f['bytes'],20000)
  s=(HERE/'fetch_public_fixtures.py').read_text()
  for token in ["hashlib.sha256(data).hexdigest()==f['sha256']",'temporary not in out.parents','root in out.parents','target.chmod(0o600)']:
   self.assertIn(token,s)
 def test_no_public_profile_material(self):
  for f in HERE.rglob('*'):
   self.assertNotIn(f.suffix,['.mobileprovision','.cer','.cms','.plist','.der'])
if __name__=='__main__':unittest.main()

#!/usr/bin/env python3
"""Actual producer/ACK-recording/consumer; real fingerprint, inert SDK boundaries."""
from pathlib import Path
import sys, hashlib, json
root=Path(__file__).resolve().parents[2]
out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
def extract(s, anchor):
 assert s.count(anchor)==1,anchor
 a=s.index(anchor);i=s.index('{',a)+1;depth=1
 while depth:
  depth+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[a:i]
install=root/'SideStore/Core/Operations/PipelineOperations/InstallAppOperation.swift'
runner=root/'SideStore/Core/Operations/PipelineRunner.swift'
contexts=root/'SideStore/Core/Operations/OperationContexts.swift'
fingerprint=root/'SideStore/Utils/common/AppBundleFingerprint.swift'
producer=extract(install.read_text(),'private func acknowledgedReuseMainIdentity(')
s=install.read_text();a=s.index('            // Capture what the signer actually installed,')
b=s.index('\n        }',a)
ack=s[a:b]
# Enforce real recording block is after successful native dispatch, not a fixture assertion.
assert a>s.index('try await installIPA(bundleID)') and a>s.index('try await installAppBundle(bundleID')
assert a>s.index('let acknowledged = V3RefreshVerification()')
s=runner.read_text();a=s.index('            let identityInputs = await group.dbContext.perform')
b=s.index('            context.validatedReuseMain = false',a)+len('            context.validatedReuseMain = false')
consumer=s[a:b]
here=root/'tests/reuse_main'
code='import Foundation\n'+extract(contexts.read_text(),'enum V3ValidatedReuseMainRegistry {')+'\n'
code+=(here/'ProducerConsumerDoubles.swift').read_text()+'\n'
code+='@MainActor final class ProducerHarness { let context: FixtureContext; init(_ c:FixtureContext) { context=c }\n'+producer+'\n'
code+='func acknowledged(_ installedApp:InstalledApp, _ resignedAppBundle:ALTApplication, _ certificate:ALTCertificate) async { let backgroundContext=FixtureDB()\n'+ack+'\n}\n}\n'
code+='@MainActor final class ConsumerHarness { let context:FixtureContext; let group=FixtureGroup(); init(_ c:FixtureContext) { context=c }; func consume(_ app:InstalledApp) async {\n'+consumer+'\n}\n}\n'
code+=(here/'ProducerConsumerCases.swift').read_text()
(out/'ProducerConsumer.swift').write_text(code)
(out/'Fingerprint.swift').write_text(fingerprint.read_text())
inputs=[install,runner,contexts,fingerprint,Path(__file__),here/'ProducerConsumerDoubles.swift',here/'ProducerConsumerCases.swift']
(out/'producer-consumer-sources.json').write_text(json.dumps({'schema':'reuse-main-producer-consumer-source-v1','swift_executed':False,'inputs':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}},indent=2)+'\n')

#!/usr/bin/env python3
"""Generate full SideSign auth plus actual SideStore retry consumer/sequence. Offline only."""
from pathlib import Path
import argparse, hashlib, importlib.util, json
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module);return module
def generate(output,sidesign_root):
 auth=load('auth_source_generator',sidesign_root/'.ci/auth-request-diagnostics/generate.py')
 extraction=load('onboarding_extraction',ROOT/'.ci/iloader-onboarding-scope/generate.py')
 evidence=auth.generate(output)
 inputs={str(sidesign_root/path):value for path,value in evidence['inputs'].items()}
 extractor=ROOT/'.ci/iloader-onboarding-scope/generate.py'
 inputs[str(extractor)]=hashlib.sha256(extractor.read_bytes()).hexdigest()
 def read(path):
  p=ROOT/path;inputs[str(p)]=hashlib.sha256(p.read_bytes()).hexdigest();return p.read_text()
 app=read('AltStore/AppDelegate.swift')
 sequence=read('SideStore/Core/Anisette/V3DiagnosticProviderSequence.swift')
 operation=read('SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift')
 parts=[sequence]
 for anchor in ['struct V3AuthenticationPhaseError:', 'func v3AuthenticationPhase<T>(', 'struct V3AnisetteAttemptError:', 'struct V3ProvisioningCauseError:', 'func v3AccountUnderlyingError(']:
  parts.append(extraction.extract(app,anchor))
 mapping=extraction.extract(operation,'private func diagnosticRetryFailure(')
 parts.append('struct RetryConsumer {\nlet ownedContext: OwnedODAAuthenticationContext?\n'+mapping+'\nfunc classify(_ error: Error, appleStarted: Bool = true, provider: V3DiagnosticProvider = .onDevice) -> V3DiagnosticProviderSequence.Failure { diagnosticRetryFailure(error, appleStarted: appleStarted, provider: provider, ownedContext: ownedContext) }\n}')
 parts.append(read('.ci/initial-provider-rejection/BoundaryDoubles.swift'))
 parts.append(read('.ci/initial-provider-rejection/RuntimeCases.swift'))
 (output/'RetryConsumer.swift').write_text('\n'.join(parts))
 runtime=output/'RuntimeTests.swift';runtime.write_text(runtime.read_text().replace('try await initialProviderRejectionCases()', 'try await initialProviderRejectionCases()\n        try await initialProviderRetryConsumerCases()',1))
 outputs=sorted(p.name for p in output.glob('*.swift'))
 inputs[str(HERE/'generate.py')]=hashlib.sha256((HERE/'generate.py').read_bytes()).hexdigest()
 (output/'source-evidence.json').write_text(json.dumps({'schema':'initial-provider-rejection-source-v1','inputs':inputs,'outputs':{name:hashlib.sha256((output/name).read_bytes()).hexdigest() for name in outputs},'swift_executed':False},indent=2)+'\n')
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--output',required=True,type=Path);p.add_argument('--sidesign-root',type=Path,default=ROOT/'Dependencies/SideSign');a=p.parse_args();generate(a.output,a.sidesign_root.resolve())

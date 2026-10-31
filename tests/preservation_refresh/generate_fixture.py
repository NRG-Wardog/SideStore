#!/usr/bin/env python3
"""Compile production policy and fetch/refresh bodies with inert SDK/portal boundaries."""
import argparse, hashlib, json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def extract(s, anchor):
    assert s.count(anchor)==1, anchor
    start=s.index(anchor); end=s.index('{',start)+1; depth=1
    while depth:
        depth+=(s[end]=='{')-(s[end]=='}'); end+=1
    return s[start:end]
def generate(out):
    here=ROOT/'tests/preservation_refresh'
    refresh=ROOT/'SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift'
    fetch=ROOT/'SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift'
    service=ROOT/'AltStore/AppDelegate.swift'
    doubles=ROOT/'tests/refresh_truth/operation_doubles.swift'
    policy=extract(refresh.read_text(),'enum PreservedProfilePolicy {')
    helper=extract(fetch.read_text(),'private func fetchPreservingInstalledAuthorization()')
    # Actual dispatch must take this path before ordinary registration/group logic.
    source=fetch.read_text()
    assert source.index('if context.isPreservationRefresh {') < source.index('guard let targetAppBundle')
    assert 'return try await fetchPreservingInstalledAuthorization()' in source
    code='\n'.join(line for line in helper.splitlines() if not line.strip().startswith('//'))
    for forbidden in ['addAppID(', 'updateFeatures(', 'updateAppGroups(', 'removeProvisioning', 'resign(', 'sign(']:
        assert forbidden not in code, forbidden
    metadataPath=ROOT/'SideStore/Core/Operations/PipelineOperations/CacheResignedMetadataOperation.swift'
    metadata=metadataPath.read_text()
    assert 'if context.isPreservationRefresh' in metadata
    prefix=metadata[metadata.index('    override func execute(parentProgress:'):metadata.index('        guard let targetAppBundle')]
    metadataHarness='final class MetadataHarness: BasePipelineOperation<InstallAppOperationContext, Void> {\n'+prefix+'        fatalError("Unexpected metadata write path")\n    }\n}'
    operation='\n'.join(line for line in refresh.read_text().splitlines() if not line.startswith('import '))
    binding=extract(service.read_text(),'struct V3LegacyReplacementBinding:')
    contexts=ROOT/'SideStore/Core/Operations/OperationContexts.swift'
    registry=extract(contexts.read_text(),'enum V3ValidatedReuseMainRegistry {')
    integration='\n'.join([binding,registry,doubles.read_text(),operation,metadataHarness,(here/'BoundaryDoubles.swift').read_text(),
      'final class FetchHarness: BasePipelineOperation<InstallAppOperationContext, [String: ALTProvisioningProfile]> {\n'+helper+'\nfunc run() async throws -> [String: ALTProvisioningProfile] { try await fetchPreservingInstalledAuthorization() }\n}',
      (here/'IntegrationCases.swift').read_text()])
    out.mkdir(parents=True,exist_ok=True)
    (out/'Policy.swift').write_text('import Foundation\nimport CoreFoundation\n'+policy+'\n')
    (out/'main.swift').write_text((here/'PolicyCases.swift').read_text())
    (out/'Integration.swift').write_text(integration)
    inputs=[refresh,fetch,metadataPath,service,contexts,doubles,here/'BoundaryDoubles.swift',here/'IntegrationCases.swift',here/'PolicyCases.swift',here/'run.sh',here/'expected-cases.json',Path(__file__)]
    report={'schema':'preservation-refresh-source-v1','inputs':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},'swift_executed':False,'device_executed':False,'portal_executed':False}
    (out/'sources.json').write_text(json.dumps(report,indent=2)+'\n'); print(json.dumps(report))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);generate(p.parse_args().output)

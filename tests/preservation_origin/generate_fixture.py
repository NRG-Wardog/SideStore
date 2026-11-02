"""Exact production transport/private receipt/model/consumer, inert HTTP+SDK edges."""
from pathlib import Path
import argparse,hashlib,json
ROOT=Path(__file__).resolve().parents[2];HERE=Path(__file__).resolve().parent
SIDE=ROOT/'Dependencies/SideSign/Sources'
def extract(text,anchor):
 assert text.count(anchor)==1,anchor
 start=text.index(anchor);end=text.index('{',start)+1;depth=1
 while depth:
  depth+=(text[end]=='{')-(text[end]=='}');end+=1
 return text[start:end]
def generate(out):
 operation=SIDE/'DeveloperPortal/AppleProfileOperation.swift';models=SIDE/'Models/DeveloperPortalResponses.swift';profile=SIDE/'Models/ProvisioningProfile.swift';refresh=ROOT/'SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift'
 modeltext=models.read_text();declarations='\n'.join(extract(modeltext,a) for a in ['struct DeveloperPortalStatusResponse:','public struct AppIDPayload:','public struct ListedProvisioningProfile:','public struct ListedProfileResponse:','public struct DownloadedProfileDetails:','public struct ProfileResponse:'])
 modelsource='\n'.join(line for line in profile.read_text().splitlines() if line!='import CodeSignKit')
 library='\n'.join([(HERE/'SDKDoubles.swift').read_text(),modelsource,declarations,operation.read_text()])
 consumer=extract(refresh.read_text(),'struct V3AppleProfileOriginEvidence:')
 # Only error sink is doubled; exact authorization/installed-byte consumer stays production.
 error='enum V3PreservationRefreshState { enum Failure:Error { case preservationEvidenceUnavailable,preservationSnapshotChanged };static func failure(_ value:Failure)->Failure { value } }'
 out.mkdir(parents=True,exist_ok=True);(out/'Library.swift').write_text(library)
 (out/'Integration.swift').write_text(library+'\n'+error+'\n'+consumer+'\n'+(HERE/'TransportCases.swift').read_text())
 inputs=[operation,models,profile,refresh,HERE/'SDKDoubles.swift',HERE/'TransportCases.swift',HERE/'expected-cases.json',HERE/'run.sh',HERE/'test_contract.py',Path(__file__)]
 report={'schema':'preservation-origin-source-v1','inputs':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},'network_executed':False,'device_executed':False,'cms_verified':False,'native_executed':False}
 (out/'sources.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,sort_keys=True))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);generate(p.parse_args().output)

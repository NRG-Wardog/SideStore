"""Download explicit parser-test data only to caller's temporary directory.
Never include downloaded profile material in repository or retained CI artifacts.
"""
import argparse,hashlib,json,pathlib,tempfile,urllib.request
p=argparse.ArgumentParser();p.add_argument('--output',required=True);a=p.parse_args()
here=pathlib.Path(__file__).resolve().parent;root=here.parents[1]
out=pathlib.Path(a.output).resolve()
if out==root or root in out.parents:raise SystemExit('Public profile data must remain outside the source tree')
temporary=pathlib.Path(tempfile.gettempdir()).resolve()
if temporary not in out.parents:raise SystemExit('Public profile data requires a temporary child directory')
out.mkdir(parents=True,exist_ok=True)
manifest=json.loads((here/'public-fixtures.json').read_text())
assert manifest['schema']=='preservation-der-public-fixtures-v1' and len(manifest['fixtures'])==2
for i,f in enumerate(manifest['fixtures']):
 with urllib.request.urlopen(f['url'],timeout=60) as response:data=response.read(1_048_577)
 assert len(data)==f['bytes'] and hashlib.sha256(data).hexdigest()==f['sha256'],'Pinned public fixture mismatch'
 target=out/f'profile-{i}.cms';target.write_bytes(data);target.chmod(0o600)
print('PUBLIC_FIXTURE_ACQUISITION_PASS count=2 source_tree_write=false')

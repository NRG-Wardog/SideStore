#!/usr/bin/env python3
"""Extract unchanged actual identity gate, not a parallel behavioral model."""
import argparse, hashlib, json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--output',required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[2]
source=root/'AltStore/AppDelegate.swift';text=source.read_text()
start=text.index('final class V3AuthIdentityStampState:')
brace=text.index('{',start);depth=1;end=brace+1
while depth:
    if text[end]=='{':depth+=1
    elif text[end]=='}':depth-=1
    end+=1
out=Path(a.output).resolve();out.mkdir(parents=True,exist_ok=True)
(out/'Identity.swift').write_text('import Foundation\n'+text[start:end]+'\n')
(out/'source-evidence.json').write_text(json.dumps({'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'extracted_sha256':hashlib.sha256((out/'Identity.swift').read_bytes()).hexdigest()},indent=2)+'\n')

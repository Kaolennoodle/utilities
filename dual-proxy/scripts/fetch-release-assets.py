#!/usr/bin/env python3
"""Fetch fixed official assets. Core hashes are pinned in lib/common.sh."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import hashlib,re,subprocess
root=Path(__file__).resolve().parents[1]
out=root/'build/assets';out.mkdir(parents=True,exist_ok=True)
s=(root/'lib/common.sh').read_text()
def entries(name):
 block=re.search(r'declare -A '+name+r'=\((.*?)\n\)',s,re.S)[1]
 return dict(re.findall(r'\[([^]]+)\]="([^"]+)"',block))
jobs=[]
for component,prefix,version,base in [
 ('xray','XRAY','v26.3.27','https://github.com/XTLS/Xray-core/releases/download/v26.3.27/'),
 ('hysteria','HY','v2.13.0','https://github.com/apernet/hysteria/releases/download/app%2Fv2.13.0/')]:
 for arch,name in entries(prefix+'_ASSET').items(): jobs.append((base+name,name,entries(prefix+'_SHA256')[arch]))
jobs.append(('https://github.com/acmesh-official/acme.sh/archive/807da6498377ee5e0cf43a78091f46f12dc59a89.tar.gz','acme.sh-3.1.6.tar.gz','ddbe1bcbd1a44a2623a2af167ebdc678669e6e2eb396742f2d1d28e02dc14220'))
def fetch(job):
 url,name,expected=job;dest=out/name
 if not dest.exists():
  subprocess.run(['curl','-fsSL','--retry','2','--max-time','180','-o',str(dest)+'.part',url],check=True)
  Path(str(dest)+'.part').replace(dest)
 digest=hashlib.sha256(dest.read_bytes()).hexdigest()
 if expected and digest!=expected: raise RuntimeError('Official SHA256 mismatch: '+name)
 print(name+' sha256='+digest,flush=True)
with ThreadPoolExecutor(max_workers=5) as pool: list(pool.map(fetch,jobs))

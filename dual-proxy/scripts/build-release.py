#!/usr/bin/env python3
"""Package an already-built blog and verified vendor assets without secrets."""
from pathlib import Path
import hashlib,json,shutil,subprocess,tarfile,datetime
root=Path(__file__).resolve().parents[1]; stage=root/'build/release/dual-proxy'
if stage.exists(): shutil.rmtree(stage)
stage.mkdir(parents=True)
for name in ['deploy.sh','install.sh','manage.sh','VERSION','README.md','SECURITY.md','COMPATIBILITY.md','KNOWN-LIMITATIONS.md','BUNDLE-README.md']:
 shutil.copy2(root/name,stage/name)
for name in ['lib','templates','tests']:
 shutil.copytree(root/name,stage/name,ignore=shutil.ignore_patterns('__pycache__','.DS_Store'))
shutil.copytree(root/'build/blog/public',stage/'site')
shutil.copytree(root/'build/assets',stage/'vendor',ignore=shutil.ignore_patterns('*.part'))
assert (stage/'site/index.html').is_file()
assert len(list((stage/'vendor').iterdir()))==5
for p in stage.rglob('*'):
 if p.is_symlink(): raise RuntimeError('Symlink not allowed in bundle: '+str(p))
 if p.name in ['.git','.env','client-params.txt','id_ed25519'] or p.suffix in ['.pem','.key']:
  raise RuntimeError('Unexpected sensitive file: '+str(p))
source=root/'blog/blog-source'
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
manifest={'built_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'node':subprocess.check_output(['node','--version'],text=True).strip(),
 'blog_commit':subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip(),
 'blog_lock_sha256':sha(source/'package-lock.json'), 'blog_timezone':'UTC',
 'blog_url_policy':'preserve original configuration and HTML',
 'site_files':len([p for p in (stage/'site').rglob('*') if p.is_file()]),
 'xray':'v26.3.27','hysteria':'v2.13.0','acme_commit':'807da6498377ee5e0cf43a78091f46f12dc59a89',
 'vendor_sha256':{p.name:sha(p) for p in sorted((stage/'vendor').iterdir())}}
(stage/'BUILD-MANIFEST.json').write_text(json.dumps(manifest,indent=2)+'\n')
(stage/'SHA256SUMS').write_text(''.join(sha(p)+'  '+p.relative_to(stage).as_posix()+'\n' for p in sorted(stage.rglob('*')) if p.is_file() and p.name!='SHA256SUMS'))
root.joinpath('dist').mkdir(exist_ok=True)
archive=root/'dist/dual-proxy-bundle-20261113.tar.gz'
with tarfile.open(archive,'w:gz') as t:
 for p in [stage]+sorted(stage.rglob('*')):
  info=t.gettarinfo(str(p),arcname='dual-proxy/'+p.relative_to(stage).as_posix() if p!=stage else 'dual-proxy')
  info.uid=info.gid=0;info.uname=info.gname='root';info.mode=0o755 if p.is_dir() or p.suffix=='.sh' else 0o644
  with p.open('rb') if p.is_file() else __import__('contextlib').nullcontext() as f: t.addfile(info,f)
archive.with_suffix(archive.suffix+'.sha256').write_text(sha(archive)+'  '+archive.name+'\n')
print(str(archive));print('site files:',manifest['site_files'],'archive bytes:',archive.stat().st_size)

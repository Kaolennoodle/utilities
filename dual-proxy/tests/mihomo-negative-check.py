#!/usr/bin/env python3
"""Temporary real-client rejection tests. Never print credentials."""
import copy, json, pathlib, socket, subprocess, sys, tempfile, time
binary, source = sys.argv[1:]
base=json.loads(pathlib.Path(source).read_text())
variants={
    'wrong UUID':lambda p:p.update(uuid='00000000-0000-4000-8000-000000000000'),
    'wrong Reality public key':lambda p:p['reality-opts'].update({'public-key':'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'}),
    'wrong shortId':lambda p:p['reality-opts'].update({'short-id':'0000000000000000'}),
    'wrong SNI':lambda p:p.update(servername='wrong.invalid'),
}
for label, mutate in variants.items():
    config=copy.deepcopy(base); config['mixed-port']=17892;mutate(config['proxies'][0])
    with tempfile.TemporaryDirectory(prefix='reality-negative-') as folder:
        path=pathlib.Path(folder)/'test.json';path.write_text(json.dumps(config));path.chmod(0o600)
        process=subprocess.Popen([binary,'-d',folder,'-f',str(path)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            for _ in range(40):
                try:
                    with socket.create_connection(('127.0.0.1',17892),timeout=.2): break
                except OSError: time.sleep(.1)
            result=subprocess.run(['curl','--noproxy','','--proxy','socks5h://127.0.0.1:17892','--max-time','7','-fsS','https://example.com/'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            assert result.returncode!=0, label+' unexpectedly proxied'
            assert process.poll() is None, label+' did not reach a running client'
            print('PASS rejected '+label,flush=True)
        finally:
            process.terminate();process.wait(timeout=5)

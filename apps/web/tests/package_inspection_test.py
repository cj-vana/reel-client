import hashlib
import io
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import tempfile
import unittest
import zlib

class PackageInspectionTests(unittest.TestCase):
    def test_payload_boundary(self):
        inspector = Path(__file__).resolve().parents[1] / 'scripts/inspect-webos.py'
        with tempfile.TemporaryDirectory(prefix='reel-ipk-inspection-') as temporary:
            root = Path(temporary)
            (root / 'scripts').mkdir()
            (root / '.cache/packages').mkdir(parents=True)
            shutil.copyfile(inspector, root / 'scripts/inspect-webos.py')
            (root / 'scripts/source-revision.mjs').write_text("export async function sourceRevision(){return {revision:'synthetic-inspector-fixture'}}")
            chunk = lambda kind, data: struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
            png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b'\0\0\0\0\xff')) + chunk(b'IEND', b'')
            files = {'appinfo.json': json.dumps({'id':'app.reelclient.tv','version':'0.1.0','requiredACG':[]}).encode(), 'reel-config.js': b"window.REEL_CONFIG={previewMode:false,platform:'webos'};", 'icon.png': png, 'reel.js': b'document.body.textContent="Synthetic package fixture";'}
            prefix = 'usr/palm/applications/app.reelclient.tv/'
            for case in ['valid','valid-protected','mode-mismatch','mode-missing','mode-string','extra-service','symlink','duplicate','postinst','extra-ar-member','declared-service']:
                protected = case == 'valid-protected'
                files['reel-config.js'] = ("window.REEL_CONFIG={previewMode:" + str(protected).lower() + ",platform:'webos'};").encode()
                manifest = {'source_revision':'synthetic-inspector-fixture','protected_preview':protected,'files':{name:hashlib.sha256(data).hexdigest() for name,data in files.items()}}
                if case == 'mode-mismatch': manifest['protected_preview'] = not protected
                if case == 'mode-missing': del manifest['protected_preview']
                if case == 'mode-string': manifest['protected_preview'] = 'false'
                (root / '.cache/webos-stage-manifest.json').write_text(json.dumps(manifest))
                archive = io.BytesIO()
                with tarfile.open(fileobj=archive, mode='w:gz') as tar:
                    for name, data in files.items():
                        entry = tarfile.TarInfo(prefix + name); entry.size = len(data); tar.addfile(entry, io.BytesIO(data))
                    metadata = {'id':'app.reelclient.tv','version':'0.1.0','app':'app.reelclient.tv'}
                    if case == 'declared-service': metadata['services']=['unexpected.service']
                    data=json.dumps(metadata).encode(); entry=tarfile.TarInfo('usr/palm/packages/app.reelclient.tv/packageinfo.json'); entry.size=len(data); tar.addfile(entry,io.BytesIO(data))
                    if case == 'extra-service':
                        entry = tarfile.TarInfo('usr/palm/services/unexpected/service.js'); entry.size=5; tar.addfile(entry,io.BytesIO(b'extra'))
                    if case == 'symlink':
                        entry = tarfile.TarInfo(prefix + 'linked.js'); entry.type=tarfile.SYMTYPE; entry.linkname='/etc/passwd'; tar.addfile(entry)
                    if case == 'duplicate':
                        entry = tarfile.TarInfo(prefix + 'reel.js'); entry.size=len(files['reel.js']); tar.addfile(entry,io.BytesIO(files['reel.js']))
                (root / 'data.tar.gz').write_bytes(archive.getvalue())
                package = root / '.cache/packages/app.reelclient.tv_0.1.0_all.ipk'
                control = io.BytesIO()
                with tarfile.open(fileobj=control, mode='w:gz') as tar:
                    metadata = b'Package: app.reelclient.tv\nVersion: 0.1.0\n'
                    entry = tarfile.TarInfo('control'); entry.size=len(metadata); tar.addfile(entry,io.BytesIO(metadata))
                    if case == 'postinst':
                        hook=b'#!/bin/sh\nexit 0\n'; entry=tarfile.TarInfo('postinst'); entry.size=len(hook); tar.addfile(entry,io.BytesIO(hook))
                package_bytes = b'!<arch>\n'
                members = [('debian-binary',b'2.0\n'),('control.tar.gz',control.getvalue()),('data.tar.gz',archive.getvalue())]
                if case == 'extra-ar-member': members.append(('unexpected',b'extra'))
                for name,payload in members:
                    header = f"{name:<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(payload):<10}`\n".encode('ascii')
                    assert len(header)==60
                    package_bytes += header + payload + (b'\n' if len(payload)%2 else b'')
                package.write_bytes(package_bytes)
                result = subprocess.run(['python3',str(root / 'scripts/inspect-webos.py')],capture_output=True,text=True)
                with self.subTest(case=case):
                    self.assertEqual(result.returncode == 0, case in ('valid', 'valid-protected'), result.stderr)
                    if result.returncode == 0:
                        receipt = json.loads((root / '.cache/package-inspection.json').read_text())
                        self.assertIs(receipt['protected_preview'], protected)

if __name__ == '__main__': unittest.main()

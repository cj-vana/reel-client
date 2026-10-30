#!/usr/bin/env python3
"""Inspect and extract a locally built Reel IPK so the browser suite can test it. No TV connection."""
import hashlib
import io
import json
import shutil
from pathlib import Path
import subprocess
import sys
import tarfile

root = Path(__file__).resolve().parents[1]
package = Path(sys.argv[1]) if len(sys.argv) > 1 else root / '.cache/packages/app.reelclient.tv_0.1.0_all.ipk'
archive_members = subprocess.check_output(['ar', 't', str(package)], text=True).splitlines()
if sorted(archive_members) != ['control.tar.gz', 'data.tar.gz', 'debian-binary']:
    raise SystemExit('Unexpected or duplicate package archive member')
if subprocess.check_output(['ar', 'p', str(package), 'debian-binary']) != b'2.0\n':
    raise SystemExit('Unsupported package archive version')
control_archive = subprocess.check_output(['ar', 'p', str(package), 'control.tar.gz'])
control_metadata = None
with tarfile.open(fileobj=io.BytesIO(control_archive), mode='r:gz') as archive:
    for member in archive.getmembers():
        name = member.name.removeprefix('./')
        if member.isdir() and name in ('', '.'):
            continue
        if name != 'control' or not member.isfile() or member.size > 16384 or control_metadata is not None:
            raise SystemExit('Install hooks, links or unexpected control payload are forbidden')
        control_metadata = archive.extractfile(member).read().decode('utf8')
if control_metadata is None:
    raise SystemExit('Package control metadata is missing')
data = subprocess.check_output(['ar', 'p', str(package), 'data.tar.gz'])
destination = root / '.cache/package-unpacked'
shutil.rmtree(destination, ignore_errors=True)
destination.mkdir(parents=True, exist_ok=True)
stage_manifest = json.loads((root / '.cache/webos-stage-manifest.json').read_text())
payload_hashes = {}
prefix = 'usr/palm/applications/app.reelclient.tv/'
package_metadata_path = 'usr/palm/packages/app.reelclient.tv/packageinfo.json'
package_metadata = None
forbidden = ['private', 'tv-root-key', 'known_hosts', 'node_modules', 'fixture', 'test-results', '.env']

def assert_clean_png(data):
    if not data.startswith(b'\x89PNG\r\n\x1a\n'):
        raise SystemExit('Invalid package PNG')
    offset = 8
    while offset + 12 <= len(data):
        length = int.from_bytes(data[offset:offset + 4], 'big')
        kind = data[offset + 4:offset + 8]
        if kind in (b'tEXt', b'zTXt', b'iTXt', b'eXIf', b'tIME'):
            raise SystemExit('Annotation or EXIF metadata must be removed from package PNGs')
        offset += length + 12
        if kind == b'IEND':
            return
    raise SystemExit('Truncated package PNG')

with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
    entries = archive.getmembers()
    if any(any(word in member.name for word in forbidden) for member in entries):
        raise SystemExit('Unexpected private/test file in application package')
    for member in entries:
        name = member.name.removeprefix('./')
        if '..' in Path(name).parts or Path(name).is_absolute():
            raise SystemExit('Unsafe package member path')
        if member.isdir():
            if name in ('', '.'):
                continue
            if not (prefix.startswith(name.rstrip('/') + '/') or name.startswith(prefix) or package_metadata_path.startswith(name.rstrip('/') + '/')):
                raise SystemExit('Unexpected directory outside application payload')
            continue
        if name == package_metadata_path:
            if not member.isfile() or package_metadata is not None or member.size > 16384:
                raise SystemExit('Unexpected generated package metadata')
            package_metadata = json.loads(archive.extractfile(member).read())
            continue
        if not member.isfile() or not name.startswith(prefix):
            raise SystemExit('Unexpected file/link outside the exact application payload')
        relative = Path(name[len(prefix):])
        if relative.is_absolute() or '..' in relative.parts:
            raise SystemExit('Unsafe package member path')
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        contents = archive.extractfile(member).read()
        if member.name.endswith('.png'):
            assert_clean_png(contents)
        if relative.as_posix() in payload_hashes:
            raise SystemExit('Duplicate packaged payload file')
        payload_hashes[relative.as_posix()] = hashlib.sha256(contents).hexdigest()
        target.write_bytes(contents)
info = json.loads((destination / 'appinfo.json').read_text())
if package_metadata != {'id': info.get('id'), 'version': info.get('version'), 'app': info.get('id')}:
    raise SystemExit('Generated package metadata declares unexpected apps/services or identity')
control_fields = dict(line.split(':', 1) for line in control_metadata.splitlines() if ':' in line and not line.startswith((' ', '\t')))
if control_fields.get('Package', '').strip() != info.get('id') or control_fields.get('Version', '').strip() != info.get('version'):
    raise SystemExit('Control and application identities differ')
if info.get('id') != 'app.reelclient.tv' or info.get('requiredACG') != []:
    raise SystemExit('Unexpected application identity or permission list')
config = (destination / 'reel-config.js').read_text()
protected_preview = stage_manifest.get('protected_preview')
if type(protected_preview) is not bool:
    raise SystemExit('Staging manifest must declare the playback protection mode')
subprocess.run(['node', '-e', 'const vm=require("node:vm");const s={window:{}};vm.runInNewContext(process.argv[1],s,{timeout:500});if(s.window.REEL_CONFIG.previewMode!==JSON.parse(process.argv[2])||s.window.REEL_CONFIG.platform!=="webos")process.exit(1);', config, json.dumps(protected_preview)], check=True)
revision = subprocess.check_output(['node', '-e', 'import(require("node:url").pathToFileURL(process.argv[1]).href).then(async m=>console.log((await m.sourceRevision()).revision));', str(root / 'scripts/source-revision.mjs')], text=True).strip()
if stage_manifest.get('source_revision') != revision:
    raise SystemExit('Staged package revision is stale; rebuild it before testing')
if stage_manifest.get('files') != payload_hashes:
    raise SystemExit('Packaged payload does not match the current staging manifest')
receipt = {'source_revision': revision, 'app_id': info['id'], 'version': info['version'], 'ipk_sha256': hashlib.sha256(package.read_bytes()).hexdigest(), 'ipk_bytes': package.stat().st_size, 'required_acg': info['requiredACG'], 'protected_preview': protected_preview, 'png_annotation_exif_metadata': False, 'payload_matches_stage_manifest': True, 'payload_hashes': payload_hashes, 'control_metadata_only': True, 'generated_package_metadata_only': True, 'archive_members': archive_members, 'payload_files': sum(member.isfile() for member in entries), 'unpacked': str(destination)}
(root / '.cache/package-inspection.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))

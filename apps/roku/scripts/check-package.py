"""Source/ZIP policy validation; deliberately does not pretend to be Roku OS."""
from pathlib import Path
import hashlib,json,re,struct,sys,xml.etree.ElementTree as ET,zipfile
from importlib.util import spec_from_file_location,module_from_spec
ROOT=Path(__file__).resolve().parents[1];CHANNEL=ROOT/'channel'
(ROOT/'evidence').mkdir(exist_ok=True)
spec=spec_from_file_location('packager',ROOT/'scripts/package.py');packager=module_from_spec(spec);spec.loader.exec_module(packager)
checks=[]
def passed(name):checks.append({'id':name,'result':'passed'})
files=packager.channel_files();data={n:p.read_bytes() for n,p in files}
manifest={}
for line in data['manifest'].decode().splitlines():
 if line.strip() and not line.startswith('#'):
  k,v=line.split('=',1);assert k not in manifest;manifest[k]=v
for key in ['title','major_version','minor_version','build_version','ui_resolutions']:assert manifest[key]
assert manifest['ui_resolutions']=='fhd' and manifest['rsg_version']=='1.3';passed('manifest-and-allowlist')
components={};ids={}
for name,body in data.items():
 if name.endswith('.xml'):
  tree=ET.fromstring(body);assert tree.tag=='component';assert tree.attrib['name'] not in components;components[tree.attrib['name']]=tree
  localids=[n.attrib['id'] for n in tree.iter() if 'id' in n.attrib];assert len(localids)==len(set(localids));ids[name]=set(localids)
  for n in tree.iter():
   for k in ['uri','focusBitmapUri']:
    v=n.attrib.get(k,'')
    if not v.startswith('pkg:/') or not v:continue
    assert v[5:] in data,(name,v)
  for script in tree.findall('script'):
   uri=script.attrib['uri'];target=uri[5:] if uri.startswith('pkg:/') else str(Path(name).parent/uri)
   assert target in data,(name,target)
passed('xml-unique-ids-and-script-image-closure')
for name,body in data.items():
 if name.startswith('components/') and name.endswith('.brs'):
  xml=name[:-4]+'.xml';assert xml in ids
  for node in re.findall(r'findNode\("([^"]+)"\)',body.decode()):assert node in ids[xml],(name,node)
passed('component-findnode-identifiers')
combined='\n'.join(v.decode() for n,v in data.items() if n.endswith('.brs'))
for forbidden in [r'EnablePeerVerification\(false\)',r'EnableHostVerification\(false\)',r'\bprint\b',r'fixture-token',r'fixture-password',r'https?://(?:192\.168\.|10\.|127\.)']:
 assert not re.search(forbidden,combined,re.I),forbidden
assert 'enablePeerVerification(true)' in combined and 'enableHostVerification(true)' in combined
assert 'common:/certs/ca-bundle.crt' in combined
passed('tls-no-bypass-and-no-secret-debug-output')
operations=data['source/Operations.brs'].decode()
assert 'FormatJson(RKMetadata(r.accounts, r.device))' in operations
assert combined.count('section.write(')==1
assert 'return RKRegistryDecode(m.storage.read())' in operations
assert 'RKReconcileRecovery(result.metadata.accounts, m.accounts, RKAccountKey(m.account))' in combined
assert 'if m.metadata.inFlight <> 0' in combined
assert 'Any existing saved labels not present in this session will be removed.' in combined
assert 'if not current.canSave and r.reset <> true' in operations
assert 'section.exists("connections-v1")' in combined
assert 'saveMetadata()\n        showConnections()' not in combined
assert 'asyncStopSemantics="true"' in data['components/ReelScene.xml'].decode()
assert 'm.video.asyncStopSemantics = true' in combined
assert 'if not RKCanReleasePlayer(m.closing, m.video.state) then return' in combined
assert 'Private playback does not report history.' in combined
assert 'playSessionId: r.plan.sessionId' in operations
assert 'r.plan.accountKey' in operations
passed('metadata-only-registry-and-owned-playback-cleanup')
for entry in json.loads((ROOT/'docs/asset-pins.json').read_text())['files']:
 target=ROOT/entry['candidatePath'];assert hashlib.sha256(target.read_bytes()).hexdigest()==entry['sha256']
for name,body in data.items():
 if name.endswith('.png'):
  assert body.startswith(b'\x89PNG\r\n\x1a\n');width,height=struct.unpack('>II',body[16:24]);expected={'images/mark.png':(256,256),'images/channel-icon-hd.png':(290,218),'images/channel-icon-fhd.png':(540,405),'images/splash-hd.png':(1280,720),'images/fill-pill.9.png':(66,66),'images/fill-12.9.png':(42,42),'images/ring-card.9.png':(50,50),'images/shadow-card.9.png':(130,130),'images/scrim-left.png':(256,4),'images/scrim-bottom.png':(4,256),'images/scrim-top.png':(4,128),'images/search.png':(64,64),'images/watched.png':(36,36),'images/badge.9.png':(28,28),'images/star.png':(22,22)};assert (width,height)==expected[name]
for generated in json.loads((ROOT/'docs/platform-assets.json').read_text())['files']:
 assert hashlib.sha256((ROOT/generated['path']).read_bytes()).hexdigest()==generated['sha256']
 assert hashlib.sha256((ROOT/generated['source']).read_bytes()).hexdigest()==generated['sourceSha256']
 assert generated['rescaled'] is False and generated['sourceUnchanged'] is True
passed('exact-original-brand-bytes-and-roku-platform-canvas-dimensions')
# Build the ZIP from the current sources before comparing, so a package left in out/ by an earlier build never decides the result.
packager.package();zip_path=ROOT/'out/reel-client-roku-sideload.zip'
with zipfile.ZipFile(zip_path) as archive:
 assert set(archive.namelist())==set(data)
 assert archive.testzip() is None
 for n,b in data.items():assert archive.read(n)==b,n
passed('zip-root-layout-full-byte-match-no-test-dependencies')
report={'kind':'static-source-package-validation','result':'passed','checks':checks,'sourcePins':{n:hashlib.sha256(b).hexdigest() for n,b in data.items()},'nativeRokuOS':False}
(ROOT/'evidence/static-package.json').write_text(json.dumps(report,indent=2)+'\n')
print(f'{len(checks)} static package/policy groups passed; no Roku hardware proof')

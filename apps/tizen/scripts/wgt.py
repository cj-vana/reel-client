import hashlib,json,pathlib,stat,sys,zipfile,xml.etree.ElementTree as ET

WIDGET='{http://www.w3.org/ns/widgets}'
TIZEN='{http://tizen.org/ns/widgets}'
PRIVILEGES={'http://tizen.org/privilege/internet','http://tizen.org/privilege/tv.inputdevice'}
SIGNATURES={'author-signature.xml','signature1.xml'}
CSP="default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; media-src http: https: blob:; connect-src 'self' http: https:; font-src 'self'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"

RUNTIME_CONFIG=b"window.REEL_CONFIG = { previewMode: false, appName: 'Reel', platform: 'tizen' };\n"
def validate_runtime_config(data):
    if data!=RUNTIME_CONFIG:raise ValueError('Wrong Tizen runtime identity/config')
    return 'tizen'

def validate_config(data):
    if b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper():raise ValueError('XML declarations are forbidden')
    root=ET.fromstring(data)
    if root.tag!=WIDGET+'widget' or root.attrib.get('version')!='0.1.0' or root.attrib.get('id')!='urn:reelclient:tizen':raise ValueError('Unexpected widget identity/version')
    allowed={TIZEN+'application',TIZEN+'profile',WIDGET+'name',WIDGET+'content',WIDGET+'icon',WIDGET+'access',TIZEN+'privilege',TIZEN+'setting',TIZEN+'content-security-policy'}
    if any(child.tag not in allowed for child in root):raise ValueError('Unexpected service/metadata/config element')
    app=root.findall(TIZEN+'application')
    if len(app)!=1 or app[0].attrib!={'id':'ReelClient.Reel','package':'ReelClient','required_version':'7.0'}:raise ValueError('Unexpected application target')
    profile=root.findall(TIZEN+'profile')
    if len(profile)!=1 or profile[0].attrib.get('name')!='tv-samsung':raise ValueError('Samsung TV profile required')
    privileges=[element.attrib.get('name') for element in root.findall(TIZEN+'privilege')]
    if len(privileges)!=2 or set(privileges)!=PRIVILEGES:raise ValueError('Unexpected privileges')
    content=root.findall(WIDGET+'content');icon=root.findall(WIDGET+'icon');access=root.findall(WIDGET+'access')
    if len(content)!=1 or content[0].attrib.get('src')!='launch.html':raise ValueError('Wrong entry point')
    if len(icon)!=1 or icon[0].attrib.get('src')!='largeIcon.png':raise ValueError('Wrong icon')
    if len(access)!=1 or access[0].attrib!={'origin':'*','subdomains':'true'}:raise ValueError('Wrong user-server network policy')
    policies=root.findall(TIZEN+'content-security-policy')
    if len(policies)!=1 or ' '.join((policies[0].text or '').split())!=CSP:raise ValueError('Unsafe code policy')
    return{'appId':'ReelClient.Reel','packageId':'ReelClient','minimumTizen':'7.0','privileges':sorted(PRIVILEGES)}

def inspect(archive,receipt,signed=False):
    expected=receipt['files'];files={};directories=set();total=0
    ancestors={parent.as_posix() for name in expected for parent in pathlib.PurePosixPath(name).parents if parent.as_posix()!='.'}
    with zipfile.ZipFile(archive) as bundle:
        members=bundle.infolist()
        if len(members)>64:raise ValueError('Too many package members')
        for item in members:
            name=item.filename
            if name.startswith('/') or '\\' in name or '..' in pathlib.PurePosixPath(name).parts or name in files or name.rstrip('/') in directories:raise ValueError('Unsafe or duplicate package name')
            mode=item.external_attr>>16;kind=stat.S_IFMT(mode)
            if kind not in [0,stat.S_IFREG,stat.S_IFDIR] or item.flag_bits&1:raise ValueError('Links, special or encrypted members forbidden')
            if item.is_dir():
                if name.rstrip('/') not in ancestors:raise ValueError('Unexpected directory')
                directories.add(name.rstrip('/'));continue
            if name not in expected and not(signed and name in SIGNATURES):raise ValueError('Unexpected package payload: '+name)
            if item.file_size>8*1024*1024 or item.file_size<0:raise ValueError('Package file too large')
            total+=item.file_size
            if total>16*1024*1024:raise ValueError('Package too large')
            data=bundle.read(item)
            if len(data)!=item.file_size:raise ValueError('Truncated package file')
            files[name]={'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)}
        wanted=set(expected)|(SIGNATURES if signed else set())
        if set(files)!=wanted:raise ValueError('Incomplete package payload')
        if any(files[name]!=record for name,record in expected.items()):raise ValueError('Package differs from qualified stage')
        config=validate_config(bundle.read('config.xml'))
        config['runtimePlatform']=validate_runtime_config(bundle.read('reel-config.js'))
        if signed:
            for name in SIGNATURES:
                data=bundle.read(name)
                if b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper():raise ValueError('Signature XML declarations forbidden')
                signature=ET.fromstring(data)
                if signature.tag!='{http://www.w3.org/2000/09/xmldsig#}Signature':raise ValueError('Invalid signature document')
    return{**config,'files':files,'bytes':pathlib.Path(archive).stat().st_size,'sha256':hashlib.sha256(pathlib.Path(archive).read_bytes()).hexdigest(),'packageState':'sdk-signed-native-validation-pending' if signed else 'unsigned-not-installable','signatureAuthorityVerified':False,'nativeInstallVerified':False}

def package(stage,receipt,output):
    stage=pathlib.Path(stage);output=pathlib.Path(output)
    if stage.is_symlink() or stage.resolve()!=stage:raise ValueError('Stage must be canonical')
    if output.is_symlink():raise ValueError('Output link forbidden')
    actual={p.relative_to(stage).as_posix() for p in stage.rglob('*') if p.is_file()}
    if any(p.is_symlink() for p in stage.rglob('*')) or actual!=set(receipt['files']):raise ValueError('Unexpected staged payload')
    output.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    with zipfile.ZipFile(output,'w',compression=zipfile.ZIP_DEFLATED) as bundle:
        for name,record in sorted(receipt['files'].items()):
            data=(stage/name).read_bytes()
            if hashlib.sha256(data).hexdigest()!=record['sha256'] or len(data)!=record['bytes']:raise ValueError('Staged bytes changed: '+name)
            item=zipfile.ZipInfo(name,(2020,1,1,0,0,0));item.compress_type=zipfile.ZIP_DEFLATED;item.external_attr=(stat.S_IFREG|0o644)<<16
            bundle.writestr(item,data)
    return inspect(output,receipt)

if __name__=='__main__':
    action,receipt_path,target,*rest=sys.argv[1:];receipt=json.loads(pathlib.Path(receipt_path).read_text())
    result=package(receipt['stage'],receipt,target) if action=='package' else inspect(target,receipt,signed='--signed' in rest)
    print(json.dumps(result,indent=2))

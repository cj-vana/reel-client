"""Fictional mutable TV catalogue; isolated from retained read-only fixture users."""
import copy
import json
import re
import threading
import time
from urllib.parse import parse_qs, urlsplit
import library_contract as library

LOCK = threading.RLock()
STATES = {}
HOLDS = {}


def key(handler): return (handler.server.server_port, handler.base_path, handler.user())


def state(handler):
    return STATES.setdefault(key(handler), {'played': {}, 'requests': [], 'mode': {'countMode': 'normal'}, 'epoch': 1})


def rows(handler):
    user = handler.user()
    items = copy.deepcopy(library.catalog(user))
    for item in items:
        if item['Id']=='library-title-002':
            streams=[{'Index':0,'Type':'Video','Codec':'h264'}, {'Index':1,'Type':'Audio','Codec':'aac','DisplayTitle':'English owned AAC'}, {'Index':2,'Type':'Audio','Codec':'aac','DisplayTitle':'Spanish owned AAC'}, {'Index':3,'Type':'Subtitle','Codec':'vtt','DisplayTitle':'English owned VTT'}]
            item['MediaSources']=[{'Id':item['Id']+'-'+suffix,'Name':name,'Container':'mp4','MediaStreams':copy.deepcopy(streams)} for suffix,name in [('original','Owned original'),('alternate','Owned alternate')]]
    episodes = library._episodes(items)
    for episode in episodes:
        number = int(episode['SeriesId'].rsplit('-', 1)[1])
        season = 1 if episode['IndexNumber'] <= 2 else 2
        episode['ParentId'] = f'library-season-{number:03d}-{season}'
        episode['ParentIndexNumber'] = season
        episode['IndexNumber'] = (episode['IndexNumber']-1)%2+1
    seasons = [{'Id': f'library-season-{int(item["Id"].rsplit("-",1)[1]):03d}-{number}', 'Name':f'Season {number}', 'Type':'Season',
                'SeriesId':item['Id'], 'IndexNumber':number, 'UserData':{'Played':False}} for item in items if item['Type']=='Series' for number in [1,2]]
    groups = library._groups()
    folders = [{'Id': identifier, 'Name': 'Films' if kind=='Movie' else 'Shows', 'Type':'CollectionFolder', 'CollectionType':'movies' if kind=='Movie' else 'tvshows', 'UserData':{'Played':False}} for identifier,kind in library._LIBRARIES.items()]
    all_rows = items + episodes + seasons + groups + folders
    by_id = {row['Id']: row for row in all_rows}
    children = {row['Id']: [episode['Id'] for episode in episodes if episode['SeriesId']==row['Id']] for row in items if row['Type']=='Series'}
    children.update({row['Id']: [episode['Id'] for episode in episodes if episode['ParentId']==row['Id']] for row in seasons})
    children.update({identifier:[f'library-title-{number:03d}' for number in numbers] for identifier,numbers in library._COLLECTIONS.items()})
    children['library-playlist-1'] = [f'library-title-{number:03d}' for number in library._PLAYLIST]
    children['library-films'] = [row['Id'] for row in items if row['Type']=='Movie']
    children['library-shows'] = [row['Id'] for row in items if row['Type']=='Series']
    def leaves(identifier, seen=None):
        seen = set() if seen is None else set(seen)
        if identifier in seen: raise ValueError('Synthetic descendant cycle')
        seen.add(identifier)
        if identifier not in children: return {identifier}
        return set().union(*(leaves(child,seen) for child in children[identifier])) if children[identifier] else set()
    current = state(handler)
    for row in all_rows:
        row.setdefault('UserData', {})
        data = row['UserData']
        data['Played'] = current['played'].get(row['Id'], data.get('Played',False))
        data['PlaybackPositionTicks'] = 0 if row['Id'] in current['played'] else data.get('PlaybackPositionTicks',0)
    for identifier in children:
        descendants = leaves(identifier)
        count = sum(not by_id[leaf]['UserData']['Played'] for leaf in descendants)
        data = by_id[identifier]['UserData']; data['UnplayedItemCount'] = count
        data['Played'] = bool(descendants) and count==0
        mode = current['mode'].get('countMode','normal')
        if mode=='missing': data.pop('UnplayedItemCount',None)
        elif mode=='invalid': data['UnplayedItemCount'] = 'unknown'
        elif mode=='negative': data['UnplayedItemCount'] = -1
        elif mode=='overflow': data['UnplayedItemCount'] = 10**40
        elif mode=='zero': data['UnplayedItemCount'] = 0
        elif mode=='large': data['UnplayedItemCount'] = 123456789
    return all_rows, by_id, children, leaves


def control(handler, body):
    if not isinstance(body,dict) or not body or set(body)-{'reset','countMode','failID','failure','failures','delayID','delayMS','episodeOnly','holdID','releaseWrites','denyReads','detailID','detailType'}: raise ValueError('Named watched fixture controls required')
    if 'reset' in body and body['reset'] is not True: raise ValueError('Explicit reset only')
    if body.get('countMode','normal') not in {'normal','missing','invalid','negative','overflow','zero','large'}: raise ValueError('Unknown count mode')
    if body.get('failure','none') not in {'none','before403','before404','before503','after503','afterMalformed'}: raise ValueError('Unknown failure mode')
    for name in ['failures','delayMS']:
        if name in body and (type(body[name]) is not int or not 0<=body[name]<=(5 if name=='failures' else 3000)): raise ValueError('Bounded integer required')
    if 'episodeOnly' in body and type(body['episodeOnly']) is not bool: raise ValueError('Boolean episode-only flag required')
    if 'denyReads' in body and type(body['denyReads']) is not bool: raise ValueError('Boolean read denial required')
    if 'releaseWrites' in body and type(body['releaseWrites']) is not bool: raise ValueError('Boolean release flag required')
    if body.get('detailType','missing') not in {'missing','PluginFolder','MusicAlbum','MusicArtist','PhotoAlbum'}: raise ValueError('Named detail type fixture required')
    for name in ['failID','delayID','holdID','detailID']:
        if name in body and body[name] not in rows(handler)[1]: raise ValueError('Unknown synthetic target')
    if body.get('reset'):
        if key(handler) in HOLDS: HOLDS.pop(key(handler)).set()
        previous = state(handler)['epoch']; STATES[key(handler)]={'played':{},'requests':[],'mode':{'countMode':'normal'},'epoch':previous+1}
    if 'holdID' in body: HOLDS[key(handler)] = threading.Event()
    if body.get('releaseWrites') and key(handler) in HOLDS: HOLDS[key(handler)].set()
    state(handler)['mode'].update({name:value for name,value in body.items() if name!='reset'})
    return copy.deepcopy(state(handler)['mode'])


def handle(handler, method, path):
    if not (handler.user() or '').startswith('library-tv-watched-'): return False
    query = {name.lower():values[-1] for name,values in parse_qs(urlsplit(handler.path).query,keep_blank_values=True).items()}
    if path in {'/qa/watched-control','/qa/watched-state'}:
        if not handler.owns(): handler.respond(status=403); return True
        try:
            with LOCK:
                value = control(handler, handler.read_body()) if method=='POST' and path.endswith('control') else copy.deepcopy(state(handler)) if method=='GET' and path.endswith('state') else None
            if value is None: raise ValueError('Wrong control method')
            handler.respond(value)
        except (ValueError,TypeError,json.JSONDecodeError): handler.respond(status=400)
        return True
    watch = re.fullmatch('/UserPlayedItems/([A-Za-z0-9_-]+)',path)
    if watch and method in {'POST','DELETE'}:
        if query.get('userid',handler.user()) != handler.user(): handler.respond(status=403); return True
        with LOCK:
            all_rows, by_id, children, leaves = rows(handler)
            current = state(handler); mode=copy.deepcopy(current['mode']); epoch=current['epoch']
            receipt={'method':method,'path':path,'user':handler.user(),'basePath':handler.base_path,'atUnix':time.time(),'epoch':epoch,'committed':False}
            current['requests'].append(receipt)
            if watch[1] not in by_id: receipt['status']=404; handler.respond(status=404); return True
            failure=mode.get('failure','none') if mode.get('failID')==watch[1] and mode.get('failures',0)>0 else 'none'
            if failure!='none': current['mode']['failures']-=1
        if mode.get('holdID')==watch[1] and key(handler) in HOLDS:
            if not HOLDS[key(handler)].wait(timeout=30):
                receipt['status']=503;handler.respond({'Message':'Owned write hold expired'},status=503);return True
        if mode.get('delayID')==watch[1]: time.sleep(mode.get('delayMS',0)/1000)
        with LOCK:
            if state(handler)['epoch']!=epoch: receipt['status']=409; handler.respond(status=409); return True
            if failure.startswith('before'):
                status=int(failure[6:]);receipt['status']=status;handler.respond({'Message':'Owned synthetic watched failure'},status=status);return True
            targets=leaves(watch[1])
            for identifier in targets: current['played'][identifier]=method=='POST'
            receipt.update(committed=True,commitAtUnix=time.time(),descendants=sorted(targets),desired=method=='POST')
            value=copy.deepcopy(rows(handler)[1][watch[1]]['UserData'])
            receipt['status']=503 if failure=='after503' else 200
        if failure=='after503': handler.respond({'Message':'Synthetic response failure after commit'},status=503)
        elif failure=='afterMalformed': handler.respond({'Unexpected':'synthetic accepted response'})
        else: handler.respond(value)
        return True
    if method!='GET': return False
    if path not in {'/Items','/Items/Latest','/UserViews','/Genres','/UserItems/Resume','/Shows/NextUp'} and not re.fullmatch('/(Items/[^/]+|Shows/[^/]+/(Seasons|Episodes)|Playlists/[^/]+/Items)',path): return False
    with LOCK:
        if state(handler)['mode'].get('denyReads') and path not in {'/UserViews','/Genres'}:
            handler.respond({'Message':'Owned synthetic watched-data read failure'},status=503);return True
        all_rows, by_id, children, leaves = rows(handler); current=state(handler)
        if path.startswith('/Items/') and path!='/Items/Latest':
            value=copy.deepcopy(by_id.get(path.split('/')[-1]))
            if value and current['mode'].get('detailID')==value['Id']:
                if current['mode'].get('detailType')=='missing': value.pop('Type',None)
                else: value['Type']=current['mode']['detailType']
            handler.respond(value,status=200 if value else 404);return True
        if path=='/UserViews': values=[by_id[name] for name in library._LIBRARIES]
        elif path=='/Genres': values=[{'Id':name,'Name':title,'Type':'Genre'} for name,title in library._GENRES.items()]
        elif path.endswith('/Seasons'): values=[row for row in all_rows if row['Type']=='Season' and row['SeriesId']==path.split('/')[2]]
        elif path.endswith('/Episodes'): values=[row for row in all_rows if row['Type']=='Episode' and row['SeriesId']==path.split('/')[2] and (not query.get('seasonid') or row['ParentId']==query['seasonid'])]
        elif path.startswith('/Playlists/'):
            values=[{**copy.deepcopy(by_id[f'library-title-{number:03d}']),'PlaylistItemId':f'library-entry-{index:03d}'} for index,number in enumerate(library._PLAYLIST,1)]
        elif path in {'/UserItems/Resume','/Shows/NextUp'}: values=[]
        else:
            parent=query.get('parentid'); allowed=set(leaves(parent)) if parent in children else None
            values=[row for row in all_rows if row['Type'] not in {'Season','CollectionFolder'} and (allowed is None or row['Id'] in allowed)]
            effective={'includeitemtypes':'Movie,Series',**query}
            values=library._filter(values,effective)
            if path=='/Items/Latest': effective.update(sortby='DateCreated,SortName',sortorder='Descending,Ascending')
            values=library._sort(values,effective)
            if current['mode'].get('episodeOnly') and not (path=='/Items' and query.get('includeitemtypes')=='Episode'): values=[]
        start,limit=library._pagination(query);total=len(values);page=copy.deepcopy(values[start:start+limit])
    handler.respond(page if path=='/Items/Latest' else {'Items':page,'TotalRecordCount':total,'StartIndex':start})
    return True

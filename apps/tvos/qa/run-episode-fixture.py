#!/usr/bin/env python3
"""Fictional six-episode contract for native remote journeys on one owned loopback port."""
import json
from pathlib import Path
import sys
import time
import re
from urllib.parse import urlsplit, parse_qs

import argparse
import hashlib

ROOT = Path(__file__).resolve().parents[3]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'apps/apple/qa'))
import fixture_server
import fixture_ownership
from native_fixture_contract import native_audio_metadata

parser = argparse.ArgumentParser(description="Owned silent episode fixture; never a real Jellyfin server")
parser.add_argument('--port', type=int, choices=[18967], required=True)
parser.add_argument('--media', required=True)
args = parser.parse_args()
OWNER = fixture_ownership.owner_from_environment()
media = Path(args.media).resolve(strict=True)
if ROOT == media or ROOT in media.parents or not media.name.startswith('reel-tvos-fixture-'):
    raise SystemExit('Use a generated disposable reel-tvos-fixture-* directory outside the repository.')
try:
    marker = json.loads((media / 'silent-fixture.json').read_text())
    valid = marker.get('kind') == 'reel-tvos-silent-fixture' and marker.get('sampleSHA256') == hashlib.sha256((media / 'sample.mp4').read_bytes()).hexdigest()
except (OSError, ValueError, AttributeError):
    valid = False
if not valid or not (media / 'hls/index.m3u8').is_file():
    raise SystemExit('Generate unchanged episode media with prepare-fixtures.py --silent first.')
fixture_server.ROOT = media
control = {'failSeasons': False, 'failEpisodes': False, 'emptySeasons': False, 'emptyEpisodes': False, 'noIntro': False, 'badIntro': False, 'slowSeasons': False, 'failAdjacent': False, 'noArtwork': False, 'slowAdjacent': False, 'slowEpisodes': False}

class Handler(fixture_server.Handler):
    def respond(self, value=None, status=200, content_type='application/json'):
        return super().respond(native_audio_metadata(value), status, content_type)

    def do_GET(self):
        path = urlsplit(self.path).path
        if not fixture_ownership.admit(self, path, OWNER): return
        if path == '/System/Info/Public': return self.respond({'ServerName': 'Reel Silent Episodes', 'Version': '12.3.0'})
        user = self.user()
        if path == '/streamyfin/config':
            mode = 'auto' if user == 'tv-intro-auto' else 'none' if user == 'tv-intro-none' else 'ask'
            return self.respond({'settings': {'skipIntro': {'value': mode}}})
        if '/Images/' in path:
            if control['noArtwork']: return self.respond(status=404)
            kind = 'backdrop' if '/Backdrop' in path else 'poster'
            digits = re.search(r'\d+', path)
            index = int(digits.group()) % 6 if digits else 0
            image = media / 'artwork' / f'{kind}-{index}.png'
            if image.is_file(): return self.file(image, 'image/png')
        if path.startswith('/MediaSegments/'):
            values = [] if control['noIntro'] else [{'Id': 'intro', 'Type': 'Intro', 'StartTicks': 0, 'EndTicks': (-1 if control['badIntro'] else 10 * fixture_server.TICKS)}]
            return self.respond({'Items': values})
        if path.endswith('/Seasons'):
            if control['slowSeasons']: time.sleep(8)
            if control['failSeasons']: return self.respond(status=503)
            return self.respond({'Items': [] if control['emptySeasons'] else [{'Id': f'season-{n}', 'Name': f'Season {n}', 'IndexNumber': n, 'Type': 'Season'} for n in [1,2]]})
        if path.endswith('/Episodes'):
            if control['failEpisodes']: return self.respond(status=503)
            query = {k.lower():v[0] for k,v in parse_qs(urlsplit(self.path).query).items()}
            if 'adjacentto' in query and control['slowAdjacent']: time.sleep(15)
            if 'adjacentto' not in query and control['slowEpisodes']: time.sleep(8)
            if 'adjacentto' in query and control['failAdjacent']: return self.respond(status=503)
            values = [fixture_server.episode(n,user,s) for s in [1,2] for n in [1,2,3]]
            if 'adjacentto' not in query:
                season_id = query.get('seasonid', 'season-1')
                if season_id not in ('season-1', 'season-2'): return self.respond(status=400)
                season = int(season_id.split('-')[-1])
                values = [item for item in values if item['ParentIndexNumber']==season]
            if control['emptyEpisodes']: values=[]
            return self.respond({'Items': values, 'TotalRecordCount': len(values)})
        return super().do_GET()

    def do_POST(self):
        path=urlsplit(self.path).path
        if not fixture_ownership.admit(self,path,OWNER): return
        if path=='/qa/tv-control':
            body=self.read_body()
            if not isinstance(body, dict) or not set(body).issubset(control) or not all(isinstance(v,bool) for v in body.values()): return self.respond(status=400)
            control.update(body); return self.respond({'ok':True})
        if path=='/qa/reset': control.update(dict.fromkeys(control,False))
        return super().do_POST()

    def do_DELETE(self):
        if not fixture_ownership.admit(self, urlsplit(self.path).path, OWNER): return
        return super().do_DELETE()

print('Owned silent episode fixture on 18967', flush=True)
fixture_server.LoopbackHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()

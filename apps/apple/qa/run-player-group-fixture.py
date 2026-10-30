#!/usr/bin/env python3
"""Owned loopback SyncPlay fixture for the native player UI suite."""
import argparse
from pathlib import Path
import sys
from urllib.parse import urlsplit

repo = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(repo / 'apps/tvos/qa'))
import fixture_ownership
from native_fixture_contract import native_audio_metadata
import fixture_server
import remote_contract

parser = argparse.ArgumentParser()
parser.add_argument('--media', required=True)
args = parser.parse_args()
media = Path(args.media).resolve(strict=True)
if repo == media or repo in media.parents or not media.name.startswith('reel-tvos-fixture-'):
    raise SystemExit('Use a generated disposable reel-tvos-fixture-* directory outside source.')
if not (media / 'sample.mp4').is_file():
    raise SystemExit('Generate the synthetic media first.')
fixture_server.ROOT = media
owner = fixture_ownership.owner_from_environment()

class OwnedHandler(remote_contract.Handler):
    def respond(self, value=None, status=200, content_type='application/json'):
        return super().respond(native_audio_metadata(value), status, content_type)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/qa/tv-identity':
            return self.respond({'kind': 'reel-tv-owned-fixture', 'owner': owner, 'port': 18974})
        if not fixture_ownership.admit(self, path, owner):
            return
        return super().do_GET()

    def do_POST(self):
        if not fixture_ownership.admit(self, urlsplit(self.path).path, owner):
            return
        return super().do_POST()

server = remote_contract.LoopbackHTTPServer(('127.0.0.1', 18974), OwnedHandler)
print('Owned player SyncPlay fixture on 127.0.0.1:18974', flush=True)
server.serve_forever()

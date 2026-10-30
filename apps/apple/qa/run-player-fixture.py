"""Owned loopback fixture for native player controls and episode navigation.

Run with the existing TV fixture --port18966 and --media arguments. The shared
runner validates the owner nonce, loopback port and disposable media directory.
REEL_PLAYER_QA_ARTWORK optionally names a folder with the three sample PNGs.
"""
import runpy
import os
import sys
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import time
repo = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(repo / 'apps/apple/qa'))
sys.path.insert(0, str(repo / 'apps/tvos/qa'))
import fixture_server
original_get = fixture_server.Handler.do_GET
original_post = fixture_server.Handler.do_POST
episode_state = {key: False for key in ("seasonsFail", "seasonsEmpty", "episodesFail", "episodesEmpty", "episodesDelay", "noSegments", "delayPreparation", "delayStream", "autoIntro", "hideIntro", "seasonsDelay", "missingEpisodeArtwork", "emptySeriesMetadata", "missingSeasonIndex")}
original_episode = fixture_server.episode
def episode_with_metadata(number, user='demo', season=1):
    item = original_episode(number, user, season)
    if user.startswith('tv-episode-player-') and episode_state['emptySeriesMetadata']: item['SeriesId'] = ''
    if user.startswith('tv-episode-player-') and episode_state['missingSeasonIndex']: item.pop('ParentIndexNumber', None)
    return item
fixture_server.episode = episode_with_metadata
artwork_path = os.environ.get("REEL_PLAYER_QA_ARTWORK")
artwork = Path(artwork_path).resolve() if artwork_path else None
images = {'movie-1': 'quiet-earth.png', 'movie-2': 'after-last-light.png', 'movie-3': 'out-of-blue.png'}
def get_with_artwork(self):
    path = urlsplit(self.path).path
    query = {key.lower(): values[0] for key, values in parse_qs(urlsplit(self.path).query).items()}
    if path.startswith('/Videos/') and (query.get('apikey') == 'fixture-tv-player-timeout' or query.get('apikey', '').startswith('fixture-tv-episode-player-') and episode_state['delayStream']):
        deadline = time.monotonic() + 40
        while (episode_state['delayPreparation'] or episode_state['delayStream']) and time.monotonic() < deadline: time.sleep(0.05)
    if (self.user() or '').startswith('tv-episode-player-'):
        if path == '/streamyfin/config':
            mode = 'none' if episode_state['hideIntro'] else 'auto' if episode_state['autoIntro'] else 'ask'
            return self.respond({'settings': {'skipIntro': {'value': mode}}})
        if path.startswith('/Items/episode-') and '/Images/' in path and episode_state['missingEpisodeArtwork']:
            return self.respond(status=404)
        if path.endswith('/Seasons'):
            deadline = time.monotonic() + 15
            while episode_state['seasonsDelay'] and time.monotonic() < deadline: time.sleep(0.05)
            if episode_state['seasonsFail']: return self.respond(status=503)
            return self.respond({'Items': [] if episode_state['seasonsEmpty'] else [{'Id': f'season-{i}', 'Name': f'Season {i}', 'Type': 'Season', 'SeriesId': 'series-7', 'IndexNumber': i} for i in (1, 2)]})
        if path.endswith('/Episodes'):
            deadline = time.monotonic() + 15
            while episode_state['episodesDelay'] and time.monotonic() < deadline: time.sleep(0.05)
            if episode_state['episodesFail']: return self.respond(status=503)
            season = int(query.get('seasonid', 'season-1').split('-')[-1])
            seasons = (1, 2) if query.get('adjacentto') else (season,)
            items = [fixture_server.episode(i, self.user(), season) for season in seasons for i in (1, 2, 3)]
            if episode_state['missingEpisodeArtwork']:
                for item in items: item['ImageTags'] = {'Primary': 'missing-artwork'}
            return self.respond({'Items': [] if episode_state['episodesEmpty'] else items})
        if path.startswith('/MediaSegments/'):
            return self.respond({'Items': [] if episode_state['noSegments'] else [{'Id': 'intro', 'Type': 'Intro', 'StartTicks': 0, 'EndTicks': 80_000_000}]})
    components = path.split('/')
    if artwork is not None and len(components) == 5 and components[1] == 'Items' and components[2] in images and components[3] == 'Images' and components[4] in ('Primary', 'Backdrop', 'Thumb') and self.user() != 'missingart':
        return self.file(artwork / images[components[2]], 'image/png')
    return original_get(self)
def post_with_episode_controls(self):
    if urlsplit(self.path).path == '/qa/episode-control':
        body = self.read_body()
        if not isinstance(body, dict) or not set(body).issubset(episode_state) or not all(type(value) is bool for value in body.values()): return self.respond(status=400)
        episode_state.update(body)
        return self.respond({'ok': True})
    return original_post(self)
fixture_server.Handler.do_GET = get_with_artwork
fixture_server.Handler.do_POST = post_with_episode_controls
runpy.run_path(str(repo / 'apps/tvos/qa/run-fixture.py'), run_name='__main__')

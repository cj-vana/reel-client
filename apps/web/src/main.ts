import './styles/index.css';
import { setupPWA } from './pwa.ts';
import { featuredTitles, viewingProgress } from './discovery.ts';
import { loadEpisodeContext, loadSeasonEpisodes, loadIntroSegment, type EpisodeContext } from './playback-extras.ts';
import { removeConnectionAndRevoke, revokeUnusedSession } from './connection-actions.ts';
import { refreshWatchedDetail } from './detail-status.ts';
import { DesktopBrowsePreferences } from './desktop-browse.ts';
import type { BrowseCleanupNotice } from './browse-bridge.ts';
import { captureBrowseFocus, restoreBrowseFocus, type BrowseFocus } from './library-focus.ts';
import { LibraryBrowser, WatchedActions, durableBrowseStorage, hasBrowseAlias } from './library-browser.ts';
import { renderLibrary as libraryHTML, renderWatchedDialog, escapeBrowse, watchedActionLabel } from './library-view.ts';
import { itemWatched, isKnownLeafItem, supportsWatchedMutation, watchedUnavailableReason, isAggregateItem, libraryCategories, type LibraryCategory, type LibraryScope, type LibrarySort } from './library-query.ts';
import { ApiError, type ArtworkShape, JellyfinAPI, readBlob } from './api.ts';
import { ArtworkCache } from './artwork.ts';
import { icon } from './icons.ts';
import { communityRating, mediaBadges } from './media-facts.ts';
import { currentTab, installNavigation, navigationVisible, restoreFocus, revealTV } from './navigation.ts';
import { installTVConnectionForm } from './tv-connections.ts';
import { ReelPlayer } from './player.ts';
import { playbackQualities, playbackSources, playbackTracks, validPlaybackSelection, selectPlaybackSource, type PlaybackSelection } from './playback-settings.ts';
import { installPlayerPresentation, togglePlayerFullscreen, exitPlayerFullscreen, installPageCacheRecovery, restoreAfterNavigation, scrollFormatPanel, statusContainer, playerActivationAllowed, playbackTime } from './player-presentation.ts';
import { runtimeConfig, runtimeLayout, requestPlatformBack } from './runtime.ts';
import { browserStorage, Connections, deviceId } from './storage.ts';
import { DesktopLifecycle, DesktopSession, desktopAccount, desktopBridge, desktopError, uncertainDesktopError } from './desktop.ts';
import { type ItemPage, type MediaItem, episodeCode, resumeSeconds, subtitle, TICKS, duration } from './types.ts';

async function boot(): Promise<void> {
const config = runtimeConfig(window.REEL_CONFIG);
const layout = runtimeLayout(config.platform);
document.documentElement.dataset.platform = config.platform;
document.documentElement.dataset.layout = layout;
const bridge = desktopBridge(window.ReelDesktop, config.platform === 'desktop');
const lifecycle = bridge ? new DesktopLifecycle(bridge) : undefined;
if (bridge) document.querySelector('#app')!.innerHTML = '<main class="empty" role="status"><div class="spinner"></div><h1>Opening your secure connections.</h1><p>Your library will be ready in a moment.</p></main>';
const initial = bridge ? await bridge.initialize() : undefined;
if (lifecycle?.closing) return;
if (initial && !initial.ok) throw desktopError(initial.code);
const desktop = bridge && initial?.ok ? new DesktopSession(bridge, initial) : undefined;
const isClosing = () => lifecycle?.closing ?? false;
const pendingWork = new Set<Promise<unknown>>();
function track<T>(work: Promise<T>): Promise<T> { pendingWork.add(work); void work.then(() => pendingWork.delete(work), () => pendingWork.delete(work)); return work; }
const storage = desktop?.storage ?? browserStorage();
const connections = new Connections(storage, desktop?.persistence);
const device = deviceId(storage);
const artwork = new ArtworkCache();
const app = document.querySelector<HTMLDivElement>('#app')!;
const items = new Map<string, MediaItem>();
const positions = new Map<string, number>();
let quality = Number(storage.getItem('reel.quality') ?? 120_000_000);
let history = storage.getItem('reel.history') === 'true';
let currentAPI: JellyfinAPI | null = null;
let routeController = new AbortController();
let routeGeneration = 0;
let stopArt: (() => void) | undefined;
let stopEpisodeArt: (() => void) | undefined;
type HomeEpisodeState = { returnFocusAnchor?: HTMLElement; generation: number; signal: AbortSignal; api: JellyfinAPI; accountId: string; accountToken: string; status: 'loading' | 'ready' | 'error'; media: MediaItem[]; error?: unknown; published: boolean; explicitRefresh: boolean };
let homeEpisodeState: HomeEpisodeState | undefined;
let homeFeatures: MediaItem[] = [];
let homeFeaturedID = '';
let nextEpisode: MediaItem | undefined;
let previousEpisode: MediaItem | undefined;
let autoNext = storage.getItem('reel.autoplay') !== 'false';
let currentPlayingItem: MediaItem | undefined;
let playingId = 0;
let playing = false;
let playerTransitionPending = false;
let searchTimer: ReturnType<typeof setTimeout> | undefined;
const desktopBrowse = config.platform === 'desktop' ? new DesktopBrowsePreferences(window.ReelBrowsePreferences, () => { const account = connections.active; return !isClosing() && !desktop?.requiresReopen && account ? { account: { server: account.server, userId: account.userId }, owner: String(connections.revision) + '|' + account.id } : undefined; }) : undefined;
const browser = new LibraryBrowser(durableBrowseStorage(() => window.localStorage), desktopBrowse);
let cleanupNotices: readonly BrowseCleanupNotice[] = [];
const dismissedCleanupNotices = new Set<string>();
const watchedActions = new WatchedActions();
let dialogReturnFocus: HTMLElement | null = null;
let dialogReturnIdentity: BrowseFocus | undefined;
let searchDraft = 0;
let browseFiltersExpanded = false;
let seasons: MediaItem[] = [];
let selectedSeason = '';
let episodes: MediaItem[] = [];
let detail: MediaItem | undefined;
let similarItems: MediaItem[] = [];
let nextUp: MediaItem | undefined;
// Skip buttons, arrow keys and media keys move this far, as on the other Reel clients.
const skipSeconds = 10;
let selectedMediaSource = '';
let selectedAudio = '';
let selectedSubtitle = '';
// The Audio and subtitles menu stays open while its choices re-render Details.
let trackMenuOpen = false;
let seasonLoading = false;
let detailStatusRead = 0;
let connectionCommit = false;
let connectionChangePending = false;
let replaceSavedPending = false;
let mobileMoreOpen = false;
const mobileNavigation = window.matchMedia('(max-width: 767px)');
const tabletNavigation = window.matchMedia('(min-width: 768px) and (max-width: 1199px)');
// The sidebar starts collapsed on tablets and expanded on desktops until the viewer chooses.
function applyRailState(): void {
  if (layout === 'tv') { delete document.documentElement.dataset.rail; return; }
  const saved = storage.getItem('reel.sidebar');
  document.documentElement.dataset.rail = saved === 'collapsed' || saved === 'expanded' ? saved : tabletNavigation.matches ? 'collapsed' : 'expanded';
}
applyRailState();
if (config.platform === 'desktop' && /Mac/.test(navigator.platform)) document.documentElement.dataset.os = 'mac';
const busyConnectionForms = new WeakMap<HTMLFormElement, Map<HTMLInputElement | HTMLButtonElement | HTMLSelectElement, boolean>>();
const pendingMutations = new Set<string>();
const mutationKey = (kind: string, id: string) => `${connections.revision}|${connections.activeId}|${id}|${kind}`;

type HomeFocus = { id: string; action: string; shelf: string; offset: number };
type Route = { homeFocus?: HomeFocus; name: string; item?: string; parent?: string; query?: string; filter?: string; sort?: string; library?: string; parentType?: string; intent?: 'newest-episodes'; scrollY?: number; focusId?: string; focusItem?: string; playerFocus?: 'episode-play'; focus?: BrowseFocus; clearFilters?: boolean };
let route: Route = { name: connections.active ? 'Home' : 'Connections' };
const backStack: Route[] = [];

const escape = (value: unknown): string => String(value ?? '').replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]!);
const selected = (value: unknown, expected: unknown): string => value === expected ? ' selected' : '';
const button = (action: string, label: string, symbol?: string, cls = 'button', data = ''): string => `<button class="${cls}" data-action="${action}" aria-label="${escape(label)}" ${data}>${symbol ? icon(symbol) : ''}<span>${escape(label)}</span></button>`;

function api(): JellyfinAPI {
  if (isClosing()) throw new ApiError('Reel is closing.');
  if (desktop?.requiresReopen) throw desktopError('uncertain');
  if (!currentAPI) throw new ApiError('Choose a connection to open your library.');
  return currentAPI;
}
function updateAPI(): void {
  if (isClosing()) return;
  const account = connections.active;
  currentAPI = account ? new JellyfinAPI(account, account.server, device, config.previewMode, history, () => history && connections.active?.id === account.id && connections.active?.token === account.token) : null;
}
updateAPI();

const navigation = [
  ['Home', 'home'], ['Library', 'library'], ['Search', 'search'], ['Favorites', 'heart'],
  ['Music', 'music'], ['Photos', 'photo'], ['Books', 'book'], ['Live TV', 'live'], ['Devices', 'device']
];

app.innerHTML = `<div class="app-shell"><aside id="rail" aria-label="Main navigation"></aside><main id="content" tabindex="-1"></main></div><div id="toast" class="toast" role="status" hidden></div><section id="player" class="player" role="dialog" aria-modal="true" aria-label="Video player" hidden>
  <header class="player-header" data-player-overlay>
    <button class="icon-button" data-action="close-player" aria-label="Close player">${icon('back')}</button>
    <div class="player-heading"><strong id="player-title"></strong><span id="player-subtitle"></span></div>
    <div class="player-header-actions">
      <button class="icon-button" id="format-toggle" data-action="format" aria-label="Playback options" aria-expanded="false" aria-controls="player-format">${icon('settings')}<span>Playback options</span></button>
      <button class="icon-button" data-action="fullscreen" aria-label="Full screen" ${layout === 'tv' ? 'hidden' : ''}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" aria-hidden="true"><path d="M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5"/></svg><span>Full screen</span></button>
    </div>
  </header>
  <div class="player-content">
    <section id="player-format" class="player-format" role="dialog" aria-modal="true" aria-label="Playback options" hidden>
      <header><div><h2 id="player-panel-heading">Playback options</h2><p id="player-panel-context" hidden></p></div>${button('close-format', 'Close playback options', 'close', 'icon-button')}</header>
      <div class="playback-tabs" role="tablist" aria-label="Playback menu">${layout === 'tv'
        // TV splits the options into tvOS-style tabs; the last one keeps speed, chapters and auto-play.
        ? `<button id="player-episodes-tab" role="tab" data-action="player-panel" data-panel="episodes" aria-selected="false" aria-controls="player-episodes-content" hidden>Episodes</button>${[['audio', 'Audio'], ['subtitles', 'Subtitles'], ['quality', 'Quality']].map(([section, label]) => `<button role="tab" data-action="player-panel" data-panel="options" data-section="${section}" aria-selected="false" aria-controls="player-options-content">${label}</button>`).join('')}<button id="player-options-tab" role="tab" data-action="player-panel" data-panel="options" data-section="general" aria-selected="true" aria-controls="player-options-content">Options</button>`
        : '<button id="player-options-tab" role="tab" data-action="player-panel" data-panel="options" aria-selected="true" aria-controls="player-options-content">Options</button><button id="player-episodes-tab" role="tab" data-action="player-panel" data-panel="episodes" aria-selected="false" aria-controls="player-episodes-content" hidden>Episodes</button>'}</div>
      <div id="player-options-content" role="tabpanel" aria-labelledby="player-options-tab"><section class="player-picture-settings" aria-label="Picture &amp; sound"><h3>Picture &amp; sound</h3><div id="player-picture-controls"></div></section><div class="playback-settings">
        <label data-setting="general">Speed<select id="speed" aria-label="Playback speed"><option value="0.25">0.25×</option><option value="0.5">0.5×</option><option value="0.75">0.75×</option><option value="1" selected>Normal</option><option value="1.25">1.25×</option><option value="1.5">1.5×</option><option value="1.75">1.75×</option><option value="2">2×</option></select></label>
        <label id="chapters-label" data-setting="general" hidden>Chapter<select id="chapters" aria-label="Chapter"></select></label>
        <label class="playback-autoplay checkbox switch" data-setting="general"><span>Auto-play next episode</span><input type="checkbox" role="switch" id="player-autoplay" ${autoNext ? 'checked' : ''} /></label>
      </div>
      <details class="playback-details" data-setting="general"><summary tabindex="0">Stream details</summary><span id="player-method" class="eyebrow"></span><div id="player-format-data" tabindex="0"></div></details></div>
      <div id="player-episodes-content" role="tabpanel" aria-labelledby="player-episodes-tab" hidden><div id="player-episode-list"></div></div>
    </section>
    <div class="screen"><video id="video" ${layout === 'tv' ? '' : 'controls'} playsinline></video><div id="player-state" class="player-state" role="status" aria-live="polite"></div></div>
    <div id="player-sync" class="player-sync" role="status"></div>
    <button id="player-skip-intro" class="button quiet" data-action="skip-intro" data-player-contextual hidden>Skip intro</button>
    <footer class="player-companion" data-player-overlay>
      <div class="transport" id="tv-transport" ${layout === 'tv' ? '' : 'hidden'}>
        <div class="player-timeline"><span id="player-elapsed">0:00</span><input id="player-seek" type="range" min="0" max="0" step="1" value="0" aria-label="Playback position" disabled /><span id="player-duration">0:00</span></div>
        <div class="player-transport-actions">
          <button class="icon-button" data-action="skip-back" aria-label="Back 10 seconds"><svg viewBox="0 0 32 32" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 6v6h6M8 12a11 11 0 1 1-2 8"/><text x="16" y="23" text-anchor="middle" fill="currentColor" stroke="none" font-size="12">10</text></svg><span>Back 10 seconds</span></button>
          ${button('toggle-play', 'Play / pause', 'pause', 'icon-button player-play')}
          <button class="icon-button" data-action="skip-forward" aria-label="Forward 10 seconds"><svg viewBox="0 0 32 32" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M24 6v6h-6M24 12a11 11 0 1 0 2 8"/><text x="16" y="23" text-anchor="middle" fill="currentColor" stroke="none" font-size="12">10</text></svg><span>Forward 10 seconds</span></button>
        </div>
      </div>
      <div id="up-next" hidden><div class="player-episode-navigation">
        ${button('play-previous', 'Previous episode', 'back', 'icon-button', 'disabled')}
        ${button('player-episodes', 'Episodes', 'library', 'icon-button')}
        ${button('play-next', 'Next episode', 'arrow', 'icon-button', 'disabled')}
      </div></div>
    </footer>
  </div>
</section><section id="photo-viewer" class="photo-viewer" role="dialog" aria-modal="true" aria-label="Photo viewer" hidden><button class="icon-button" data-action="close-photo" aria-label="Close photo">${icon('close')}</button><img id="photo-full" alt="" /></section>`;
const content = document.querySelector<HTMLElement>('#content')!;
const playerElement = document.querySelector<HTMLElement>('#player')!;
const photoElement = document.querySelector<HTMLElement>('#photo-viewer')!;
const video = document.querySelector<HTMLVideoElement>('#video')!;
const player = new ReelPlayer(video, config.platform);
const presentation = installPlayerPresentation(playerElement, video, [content, document.querySelector<HTMLElement>('#rail')!], layout === 'tv');
let playerReturnRoute: Route | undefined;
const playerState = document.querySelector<HTMLElement>('#player-state')!;
const formatPanel = document.querySelector<HTMLElement>('#player-format')!;
const formatToggle = document.querySelector<HTMLButtonElement>('#format-toggle')!;
const seekControl = document.querySelector<HTMLInputElement>('#player-seek')!;
let scrubbing = false;
let panelReturnFocus: HTMLElement | null = null;
let episodeContext: EpisodeContext | undefined;
let episodeLoading = false, episodeError = '';
let extraController: AbortController | undefined, seasonController: AbortController | undefined;
let stopPlayerArt: (() => void) | undefined, stopEndedArt: (() => void) | undefined;
let introSegment: { start: number; end: number } | undefined;
let autoNextTimer: ReturnType<typeof setTimeout> | undefined;
let autoNextCancelled = false;
let playbackSelection: PlaybackSelection | undefined;
type PlaybackChange = { previous: PlaybackSelection; desired: PlaybackSelection; position: number; paused: boolean; generation: number; accountId: string; token: string };
let playbackChange: PlaybackChange | undefined;
let playbackGeneration = 0;
function renderPictureSettings(): void {
  const node = document.querySelector<HTMLElement>('#player-picture-controls')!, item = currentPlayingItem, selection = playbackSelection;
  if (!item || !selection) { node.replaceChildren(); return; }
  const sources = playbackSources(item), source = sources.find(source => source.Id === selection.source) ?? sources[0];
  const audio = playbackTracks(source, 'Audio'), subtitles = playbackTracks(source, 'Subtitle');
  const disabled = playerTransitionPending || playerElement.dataset.state === 'preparing' || playerElement.dataset.state === 'ended';
  const field = (id: string, label: string, choices: Array<{ value: string; label: string }>, value: string, unavailable = false) => `<label data-setting="${id === 'player-audio' ? 'audio' : id === 'player-subtitles' ? 'subtitles' : 'quality'}">${label}<select id="${id}"${disabled || unavailable ? ' disabled' : ''}>${choices.map(choice => `<option value="${escape(choice.value)}"${selected(value, choice.value)}>${escape(choice.label)}</option>`).join('')}</select></label>`;
  const tracks = (values: typeof audio) => values.map(track => ({ value: String(track.Index), label: track.DisplayTitle ?? track.Language ?? 'Track ' + track.Index }));
  const focusedId = node.contains(document.activeElement) ? (document.activeElement as HTMLElement).id : undefined;
  node.innerHTML = field('player-quality', 'Quality', playbackQualities.map(quality => ({ value: String(quality.value), label: quality.label })), String(selection.bitrate))
    + field('player-audio', 'Audio', [{ value: '', label: audio.length ? 'Server default' : 'No audio tracks' }, ...tracks(audio)], selection.audio === undefined ? '' : String(selection.audio), !audio.length)
    + field('player-subtitles', 'Subtitles', [{ value: '', label: 'Server default' }, { value: '-1', label: 'Off' }, ...tracks(subtitles)], selection.subtitle === undefined ? '' : String(selection.subtitle))
    + (sources.length > 1 ? field('player-version', 'Version', sources.map((source, index) => ({ value: source.Id, label: 'Version ' + (index + 1) + (source.Container ? ' · ' + source.Container.toUpperCase() : '') })), source?.Id ?? '') : '');
  if (focusedId && !formatPanel.hidden) node.querySelector<HTMLSelectElement>('#' + focusedId + ':not([disabled])')?.focus({ preventScroll: true });
}
function changePlaybackSettings(desired: PlaybackSelection): void {
  const item = currentPlayingItem, account = connections.active, previous = playbackSelection;
  if (!playing || isClosing() || playerTransitionPending || !item || !account || !previous || !validPlaybackSelection(item, desired)) { renderPictureSettings(); return; }
  const prior = playbackChange;
  const position = prior?.position ?? (Number.isFinite(video.currentTime) ? Math.max(0, video.currentTime) : 0), paused = prior?.paused ?? video.paused;
  closePlayerExtras();
  const generation = ++playingId;
  playbackChange = { previous: prior?.previous ?? previous, desired, position, paused, generation, accountId: account.id, token: account.token };
  playbackSelection = desired; playerTransitionPending = true;
  playbackGeneration = generation;
  showFormat(false); renderPictureSettings(); updateEpisodeControls();
  void track(player.open(api(), item, { ...desired, start: position, paused }));
  void track(loadPlayerExtras(item, generation));
}

function cancelAutoNext(cancelled = false): void {
  if (cancelled && video.ended) autoNextCancelled = true;
  if (autoNextTimer !== undefined) clearTimeout(autoNextTimer);
  autoNextTimer = undefined;
  const label = document.querySelector<HTMLElement>('#autoplay-countdown');
  if (label) { label.textContent = cancelled ? 'Auto-play cancelled' : ''; label.hidden = !cancelled; }
  document.querySelector<HTMLElement>('[data-action="cancel-autoplay"]')?.setAttribute('hidden', '');
}
function beginAutoNext(): void {
  cancelAutoNext();
  if (!autoNext || autoNextCancelled || playerTransitionPending || !nextEpisode || !playing || !video.ended || document.hidden) return;
  const generation = playingId, account = connections.active, next = nextEpisode.Id;
  let remaining = 8;
  const label = document.querySelector<HTMLElement>('#autoplay-countdown');
  const cancel = document.querySelector<HTMLElement>('[data-action="cancel-autoplay"]');
  if (!label || !cancel || !account) return;
  label.hidden = false; cancel.hidden = false;
  const tick = () => {
    if (!playing || playerTransitionPending || isClosing() || generation !== playingId || account.id !== connections.active?.id || account.token !== connections.active?.token || nextEpisode?.Id !== next || !video.ended || document.hidden || !autoNext) { cancelAutoNext(); return; }
    label.textContent = 'Next episode in ' + remaining + (remaining === 1 ? ' second' : ' seconds');
    if (remaining-- === 0) { cancelAutoNext(); void track(playItem(next, true)); }
    else autoNextTimer = setTimeout(tick, 1000);
  };
  tick();
}
function closePlayerExtras(): void {
  cancelAutoNext(); autoNextCancelled = false; playerTransitionPending = false; playbackChange = undefined; extraController?.abort(); seasonController?.abort(); stopPlayerArt?.(); stopPlayerArt = undefined;
  introSegment = undefined; episodeContext = undefined; previousEpisode = undefined; nextEpisode = undefined;
  episodeLoading = false; episodeError = '';
}
function updateEpisodeControls(): void {
  const episodic = currentPlayingItem?.Type === 'Episode' && !!currentPlayingItem.SeriesId;
  document.querySelector<HTMLElement>('#up-next')!.hidden = !episodic;
  document.querySelector<HTMLElement>('#player-episodes-tab')!.hidden = !episodic;
  playerElement.querySelector<HTMLElement>('.playback-tabs')!.hidden = !episodic && layout !== 'tv';
  playerElement.querySelector<HTMLButtonElement>('[data-action="play-previous"]')!.disabled = !previousEpisode;
  playerElement.querySelector<HTMLButtonElement>('#up-next [data-action="play-next"]')!.disabled = !nextEpisode;
}
function renderPlayerEpisodes(): void {
  stopPlayerArt?.(); stopPlayerArt = undefined;
  const node = document.querySelector<HTMLElement>('#player-episodes-content')!;
  const seasons = episodeContext?.seasons ?? [];
  node.innerHTML = `${seasons.length ? `<label class="player-season-picker">Season<select id="player-season" aria-label="Player season"${episodeLoading ? ' disabled' : ''}>${seasons.map(season => `<option value="${escape(season.Id)}"${selected(episodeContext?.selectedSeason, season.Id)}>${escape(season.Name)}</option>`).join('')}</select></label>` : ''}<div id="player-episode-list">${episodeLoading ? '<div class="player-episodes-state" role="status"><div class="spinner"></div><p>Loading episodes…</p></div>' : episodeError ? `<div class="player-episodes-state" role="alert"><p>${escape(episodeError)}</p>${button('retry-player-episodes', 'Retry episodes', undefined, 'button quiet')}</div>` : episodeContext?.episodes.length ? episodeContext.episodes.map(episode => `<button class="player-episode-choice" data-action="player-episode" data-id="${escape(episode.Id)}"${episode.Id === currentPlayingItem?.Id ? ' aria-current="true"' : ''}>${artworkHTML(episode, 'landscape', 320)}<span><strong>${escape(episode.Name)}</strong><small>${escape([Number.isSafeInteger(episode.ParentIndexNumber) ? 'S' + episode.ParentIndexNumber : '', Number.isSafeInteger(episode.IndexNumber) ? 'E' + episode.IndexNumber : '', episode.RunTimeTicks ? duration(episode.RunTimeTicks / TICKS) : '', episode.Id === currentPlayingItem?.Id ? 'Now playing' : ''].filter(Boolean).join(' · '))}</small></span>${episode.Id === currentPlayingItem?.Id ? icon('check') : icon('play')}</button>`).join('') : '<p class="player-episodes-state">No episodes are available in this season.</p>'}</div>`;
  if (currentAPI) stopPlayerArt = artwork.observe(node, currentAPI, items);
}
function selectPlayerPanel(panel: 'options' | 'episodes', section = 'general'): void {
  // TV shows one group of options per tab: audio, subtitles, quality, or the general options.
  formatPanel.dataset.section = panel === 'options' ? section : '';
  const heading = panel === 'episodes' ? 'Episodes' : 'Playback options';
  document.querySelector('#player-panel-heading')!.textContent = heading; formatPanel.setAttribute('aria-label', heading);
  const context = document.querySelector<HTMLElement>('#player-panel-context')!;
  context.textContent = currentPlayingItem?.SeriesName ?? ''; context.hidden = panel !== 'episodes' || !context.textContent;
  document.querySelector<HTMLElement>('#player-options-content')!.hidden = panel !== 'options';
  document.querySelector<HTMLElement>('#player-episodes-content')!.hidden = panel !== 'episodes';
  for (const tab of playerElement.querySelectorAll<HTMLElement>('[data-action="player-panel"]')) tab.setAttribute('aria-selected', String(tab.dataset.panel === panel && (panel === 'episodes' || (tab.dataset.section ?? 'general') === section)));
  if (panel === 'episodes') renderPlayerEpisodes();
}
async function loadPlayerExtras(item: MediaItem, generation: number): Promise<void> {
  extraController?.abort(); const controller = new AbortController(); extraController = controller;
  const provider = api(), account = connections.active;
  const current = () => !isClosing() && playing && !controller.signal.aborted && generation === playingId && account?.id === connections.active?.id && account?.token === connections.active?.token && currentPlayingItem?.Id === item.Id;
  void track(loadIntroSegment(provider, item, controller.signal).then(segment => { if (current()) { introSegment = segment; updateTransport(); } }).catch(() => undefined));
  if (item.Type !== 'Episode' || !item.SeriesId) return;
  episodeLoading = true; episodeError = ''; renderPlayerEpisodes();
  try {
    const context = await loadEpisodeContext(provider, item, controller.signal);
    if (!current()) return;
    episodeContext = context; previousEpisode = context.previous; nextEpisode = context.next;
    remember([...context.episodes, ...context.seasons, ...[context.previous, context.next].filter((value): value is MediaItem => !!value)]);
  } catch (error) { if (current()) episodeError = error instanceof Error ? error.message : 'Episodes could not be loaded. Try again.'; }
  finally { if (current()) { episodeLoading = false; updateEpisodeControls(); renderPlayerEpisodes(); if (video.ended && playerElement.dataset.state === 'ended') { const action = (document.activeElement as HTMLElement)?.dataset.action; renderEndedPlayer(); if (action) playerState.querySelector<HTMLElement>('[data-action="' + action + '"]')?.focus(); beginAutoNext(); } } }
}
async function changePlayerSeason(seasonId: string): Promise<void> {
  const item = currentPlayingItem, context = episodeContext, generation = playingId, account = connections.active;
  if (!item?.SeriesId || !context || !context.seasons.some(season => season.Id === seasonId)) return;
  seasonController?.abort(); const controller = new AbortController(); seasonController = controller;
  const current = () => !isClosing() && playing && !controller.signal.aborted && generation === playingId && account?.id === connections.active?.id && account?.token === connections.active?.token;
  episodeContext = { ...context, selectedSeason: seasonId, episodes: [] }; episodeLoading = true; episodeError = ''; renderPlayerEpisodes();
  try { const rows = await loadSeasonEpisodes(api(), item.SeriesId, seasonId, controller.signal); if (current() && episodeContext) { episodeContext.episodes = rows; remember(rows); } }
  catch (error) { if (current()) episodeError = error instanceof Error ? error.message : 'Episodes could not be loaded. Try again.'; }
  finally { if (current()) { episodeLoading = false; renderPlayerEpisodes(); document.querySelector<HTMLElement>('#player-season')?.focus(); } }
}
document.addEventListener('visibilitychange', () => { if (document.hidden) cancelAutoNext(true); });
function updateTransport(): void {
  const duration = Number.isFinite(video.duration) && video.duration > 0 ? video.duration : 0;
  const position = Math.max(0, Number.isFinite(video.currentTime) ? video.currentTime : 0);
  const disabled = ['preparing', 'error', 'ended'].includes(playerElement.dataset.state ?? 'preparing');
  seekControl.disabled = disabled || duration === 0;
  seekControl.max = String(duration);
  if (!scrubbing) seekControl.value = String(Math.min(position, duration));
  const shownPosition = scrubbing ? Number(seekControl.value) : position;
  seekControl.setAttribute('aria-valuetext', playbackTime(shownPosition) + ' of ' + playbackTime(duration));
  seekControl.style.setProperty('--progress', (duration ? shownPosition / duration * 100 : 0) + '%');
  document.querySelector('#player-elapsed')!.textContent = playbackTime(shownPosition);
  document.querySelector('#player-duration')!.textContent = video.duration === Infinity ? 'Live' : playbackTime(duration);
  const skip = document.querySelector<HTMLElement>('#player-skip-intro')!, skipWasHidden = skip.hidden;
  skip.hidden = disabled || !introSegment || !duration || introSegment.end > duration || position < introSegment.start || position >= introSegment.end;
  // TV: Skip intro takes focus when it appears, and hands it back to the picture when it goes.
  if (layout === 'tv' && skipWasHidden !== skip.hidden && formatPanel.hidden) {
    if (!skip.hidden && playerElement.contains(document.activeElement)) skip.focus({ preventScroll: true });
    else if (skip.hidden && document.activeElement === skip) video.focus({ preventScroll: true });
  }
  const toggle = playerElement.querySelector<HTMLButtonElement>('[data-action="toggle-play"]')!;
  toggle.innerHTML = icon(video.paused ? 'play' : 'pause') + '<span>Play / pause</span>';
}
for (const event of ['timeupdate', 'durationchange', 'loadedmetadata', 'play', 'pause', 'emptied']) video.addEventListener(event, updateTransport);
video.addEventListener('ratechange', () => { document.querySelector<HTMLSelectElement>('#speed')!.value = String(video.playbackRate); });
seekControl.addEventListener('input', () => { scrubbing = true; updateTransport(); });
for (const event of ['blur', 'pointercancel']) seekControl.addEventListener(event, () => { scrubbing = false; updateTransport(); });
// TV: Left and Right on the timeline move as far as the skip buttons. The range's one-second step would take
// hundreds of presses to cross a film.
seekControl.addEventListener('keydown', event => {
  if (layout !== 'tv' || (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight')) return;
  event.preventDefault(); player.skip(event.key === 'ArrowLeft' ? -skipSeconds : skipSeconds);
});
function showFormat(show: boolean): void {
  if (show) { cancelAutoNext(true); panelReturnFocus = document.activeElement as HTMLElement; }
  formatPanel.hidden = !show; formatToggle.setAttribute('aria-expanded', String(show)); presentation.setPanel(show);
  // TV opens on the selected tab, so Left and Right move between tabs and Down enters it.
  const tab = show && layout === 'tv' ? formatPanel.querySelector<HTMLElement>('.playback-tabs:not([hidden]) [aria-selected="true"]:not([hidden])') : null;
  if (tab) tab.focus();
  else if (show) restoreFocus(formatPanel);
  else if (formatPanel.contains(document.activeElement)) (panelReturnFocus?.isConnected && !panelReturnFocus.closest('[hidden]') ? panelReturnFocus : formatToggle).focus();
}


// TV tabs follow focus, as on tvOS: moving onto a tab shows its options.
formatPanel.addEventListener('focusin', event => {
  const tab = (event.target as HTMLElement).closest<HTMLElement>('[data-action="player-panel"]');
  if (layout === 'tv' && tab && tab.getAttribute('aria-selected') !== 'true') selectPlayerPanel(tab.dataset.panel === 'episodes' ? 'episodes' : 'options', tab.dataset.section);
});
formatPanel.addEventListener('keydown', event => {
  const direction = ['ArrowDown', 'PageDown'].includes(event.key) ? 1 : ['ArrowUp', 'PageUp'].includes(event.key) ? -1 : 0;
  if (direction && event.target === document.querySelector('#player-format-data') && scrollFormatPanel(event.target as HTMLElement, direction, event.key.startsWith('Page'))) { event.preventDefault(); event.stopPropagation(); }
});
function renderEndedPlayer(): void {
  // TV: the next episode waits in a card over the last frame, with its artwork and countdown.
  const card = layout === 'tv' && nextEpisode ? artworkHTML(nextEpisode, 'landscape', 600) : '';
  playerState.classList.toggle('has-next', !!card);
  playerState.innerHTML = `<span class="eyebrow">Playback finished</span><h2>${nextEpisode ? 'Up next' : 'Finished watching'}</h2>${card}${nextEpisode ? button('play-next', nextEpisode.Name, 'play', 'button primary') : ''}${currentPlayingItem ? button('replay-player', 'Play again', 'play', 'button quiet') : ''}${button('close-player', 'Back to the library', undefined, 'button quiet')}<p id="autoplay-countdown" hidden></p>${button('cancel-autoplay', 'Cancel auto-play', undefined, 'button quiet', 'hidden')}`;
  stopEndedArt?.(); stopEndedArt = card && currentAPI ? artwork.observe(playerState, currentAPI, items) : undefined;
}
player.onState = (state, message) => {
  const panelWasOpen = !formatPanel.hidden;
  if (state === 'playing' || state === 'paused') {
    const change = playbackChange;
    if (change && change.generation === playingId && change.accountId === connections.active?.id && change.token === connections.active?.token) {
      if (quality !== change.desired.bitrate) {
        quality = change.desired.bitrate; storage.setItem('reel.quality', String(quality));
        if (desktop) void track(desktop.savePreferences(quality, history, autoNext)).catch(error => { if (!recoverUncertainStore(error)) toast(error.message); });
      }
      playbackChange = undefined;
    }
    if (playbackGeneration === playingId) playerTransitionPending = false;
  } else if (state === 'error' && playbackGeneration === playingId) playerTransitionPending = false;
  if (state !== 'ended') { cancelAutoNext(); playerState.classList.remove('has-next'); stopEndedArt?.(); stopEndedArt = undefined; }
  if (state === 'error' || state === 'ended') showFormat(false);
  presentation.setState(state);
  renderPictureSettings(); updateTransport();
  const transportDisabled = state === 'preparing' || state === 'error' || state === 'ended';
  playerElement.querySelectorAll<HTMLButtonElement | HTMLSelectElement>('[data-action="skip-back"],[data-action="skip-forward"],[data-action="toggle-play"],#speed,#chapters').forEach(control => { control.disabled = transportDisabled; });
  playerState.hidden = state === 'playing' || state === 'paused';
  if (state === 'preparing' || state === 'buffering') playerState.innerHTML = `<div class="spinner"></div><h2>${message ? 'One moment.' : 'Setting the scene.'}</h2><p>${escape(message ?? 'Preparing the best stream for this screen.')}</p>`;
  if (state === 'error') playerState.innerHTML = `<div class="error-mark">!</div><h2>Let’s try that again.</h2><p>${escape(message)}</p>${button('retry-player', 'Retry from saved position', 'play', 'button primary')}${playbackChange ? button('restore-player-options', 'Use previous options', undefined, 'button quiet') : ''}${button('close-player', 'Back to the library', undefined, 'button quiet')}`;
  if (state === 'ended') { if (panelWasOpen || document.hidden) autoNextCancelled = true; renderEndedPlayer(); }
  if (state === 'ended' && !panelWasOpen) beginAutoNext();
  if (state === 'error' || state === 'ended') restoreFocus(playerState);
};
player.onMethod = method => { document.querySelector('#player-method')!.textContent = method === 'DirectPlay' ? 'DIRECT PLAY' : 'HLS STREAM'; };
player.onFormat = format => {
  const node = document.querySelector<HTMLElement>('#player-format-data')!;
  node.replaceChildren();
  if (!format) { showFormat(false); node.textContent = 'Format information is not available yet.'; }
  if (format) {
    for (const [name, facts] of [['Video', format.video], ['Audio', format.audio]] as const) {
      const row = document.createElement('p'), title = document.createElement('span');
      row.className = 'format-facts'; title.className = 'format-label'; title.textContent = name; row.append(title);
      for (const fact of facts) { const chip = document.createElement('span'); chip.className = 'format-chip'; chip.textContent = fact; row.append(chip); }
      node.append(row);
    }
    for (const value of [format.delivery, format.output, format.warning].filter(Boolean)) {
      const line = document.createElement('p'); line.textContent = value; node.append(line);
    }
  }
};
player.onPosition = (item, seconds, accountId) => { positions.set(accountId + '|' + item.Id, seconds); };
player.reports.onFailure = message => { document.querySelector('#player-sync')!.textContent = message ?? ''; };

function toast(message: string): void {
  if (isClosing()) return;
  const node = document.querySelector<HTMLElement>('#toast')!;
  statusContainer(playerElement, app, playing).append(node);
  node.textContent = message; node.hidden = false;
  setTimeout(() => { node.hidden = true; }, 7000);
}

function remember(itemsToSave: MediaItem[]): void { itemsToSave.forEach(item => items.set(item.Id, item)); }
function withPosition(item: MediaItem): MediaItem {
  const local = positions.get((connections.active?.id ?? '') + '|' + item.Id);
  return local === undefined ? item : { ...item, UserData: { ...item.UserData, PlaybackPositionTicks: Math.round(local * TICKS) } };
}

function rail(): void {
  const account = connections.active;
  const focusedLabel = document.activeElement?.closest('#rail button')?.getAttribute('aria-label');
  mobileMoreOpen = false;
  content.inert = playing;
  document.body.classList.toggle('onboarding', route.name === 'Connections' && !account && connections.all.length === 0);
  document.body.classList.toggle('signed-out', !account);
  const locked = connectionCommit || desktop?.requiresReopen;
  // Desktop puts Search first, shaped like a field. The phone tab bar keeps Home first and Search last, after
  // More, as on iPhone.
  const searchFirst = layout !== 'tv' && !mobileNavigation.matches;
  const iconOnly = layout !== 'tv' && !mobileNavigation.matches && document.documentElement.dataset.rail === 'collapsed';
  const tooltip = (name: string) => iconOnly ? ` title="${escape(name)}"` : '';
  const routeButton = ([name, symbol]: string[]) => `<button class="nav-item ${route.name === name ? 'active' : ''}${searchFirst && name === 'Search' ? ' rail-search' : ''}" data-action="nav" data-route="${escape(name)}" aria-label="${escape(name)}"${tooltip(name)} ${locked ? 'disabled' : ''}${route.name === name ? ' aria-current="page"' : ''}>${icon(symbol)}<span>${escape(name)}</span></button>`;
  const primary = navigation.slice(0, 4);
  const ordered = searchFirst ? [primary[2], primary[0], primary[1], primary[3]] : [primary[0], primary[1], primary[3]];
  const trailing = searchFirst ? '' : `<div class="nav-group mobile-primary mobile-trailing">${routeButton(primary[2])}</div>`;
  const utilities = `<div class="rail-bottom">${currentAPI?.protected ? `<div class="preview-pill"${tooltip('View only')}>${icon('shield')}<span>View only</span></div>` : ''}${routeButton(['Settings', 'settings'])}<button class="connection-button" data-action="nav" data-route="Connections" aria-label="Servers"${tooltip('Servers')} ${locked ? 'disabled' : ''}${route.name === 'Connections' ? ' aria-current="page"' : ''}><span class="avatar">${escape(account?.name.slice(0, 1).toUpperCase() ?? '+')}</span><span><strong>${escape(account?.name ?? 'Your connection')}</strong><small>${escape(account?.serverName ?? 'Connect to Jellyfin')}</small></span>${icon('connection')}</button></div>`;
  const collapsed = document.documentElement.dataset.rail === 'collapsed';
  const toggle = layout === 'tv' || !account ? '' : `<button class="icon-button rail-toggle" data-action="toggle-rail" aria-label="${collapsed ? 'Expand sidebar' : 'Collapse sidebar'}" title="${collapsed ? 'Expand sidebar' : 'Collapse sidebar'}" aria-expanded="${!collapsed}">${icon('sidebar')}<span>${collapsed ? 'Expand sidebar' : 'Collapse sidebar'}</span></button>`;
  if (layout === 'tv') document.querySelector('#rail')!.innerHTML = tvTabBar(!!locked);
  else document.querySelector('#rail')!.innerHTML = `<div class="rail-head"><button class="brand" data-action="nav" data-route="Home" aria-label="Reel home"${tooltip('Reel home')} ${locked ? 'disabled' : ''}><img src="./brand/mark.svg" alt="" /><span>Reel</span></button>${toggle}</div>${account ? `<nav aria-label="Main navigation"><div class="nav-group mobile-primary">${ordered.map(routeButton).join('')}</div><button class="nav-item mobile-more-toggle ${navigation.slice(4).some(([name]) => name === route.name) || ['Settings', 'Connections'].includes(route.name) ? 'active' : ''}" data-action="toggle-more" aria-label="More" aria-controls="mobile-more-menu" aria-expanded="false" aria-haspopup="dialog" ${locked ? 'disabled' : ''}><span class="more-glyph" aria-hidden="true">${icon('more')}</span><span>More</span></button>${trailing}<div id="mobile-more-menu" class="mobile-more-menu" aria-label="More destinations"><header class="mobile-more-header"><h2>More</h2>${button('close-more', 'Close more destinations', 'close', 'icon-button')}</header><div class="nav-group"><span class="nav-group-label">Explore</span>${navigation.slice(4, 8).map(routeButton).join('')}</div><div class="nav-group nav-utility">${navigation.slice(8).map(routeButton).join('')}</div>${utilities}</div></nav>` : utilities}`;
  syncMobileNavigation();
  if (focusedLabel) {
    const target = [...document.querySelectorAll<HTMLButtonElement>('#rail button[aria-label]')].find(control => control.getAttribute('aria-label') === focusedLabel);
    if (target && !target.disabled) {
      if (target.closest('[hidden]')) document.querySelector<HTMLElement>('.mobile-more-toggle')?.focus({ preventScroll: true });
      else target.focus({ preventScroll: true });
    }
  }
}

// TV: a top tab bar, as in the Apple TV app. Movies and Series open the library on that category;
// the other sections sit in a More menu. Detail pages keep the tab they were opened from.
let tvSection = 'Home';
function tvTabBar(locked: boolean): string {
  const account = connections.active;
  const category = route.name === 'Library' && !route.parent ? route.filter : undefined;
  const section = route.name === 'Library' && !route.parent ? category === 'Movies' ? 'Movies' : category === 'Series' ? 'Series' : 'Library'
    : navigation.slice(4).some(([name]) => name === route.name) ? 'More' : route.name;
  if (['Home', 'Movies', 'Series', 'Library', 'Search', 'Favorites', 'More', 'Settings', 'Connections'].includes(section)) tvSection = section;
  const disabled = locked ? ' disabled' : '';
  const tab = (key: string, attributes: string, label = key, cls = 'nav-item') => `<button class="${cls}${tvSection === key ? ' active tv-current' : ''}" ${attributes} aria-label="${escape(label)}"${section === key && key !== 'More' ? ' aria-current="page"' : ''}${disabled}><span>${escape(label)}</span></button>`;
  const destination = (name: string) => tab(name, `data-action="nav" data-route="${escape(name)}"`);
  const tabs = account ? `<nav class="tv-tabs mobile-primary" aria-label="Main navigation">${destination('Home')}${tab('Movies', 'data-action="home-category" data-category="Movies"')}${tab('Series', 'data-action="home-category" data-category="Series"')}${destination('Library')}${destination('Search')}${destination('Favorites')}${tab('More', 'data-action="toggle-more" aria-controls="mobile-more-menu" aria-expanded="false" aria-haspopup="dialog"', 'More', 'nav-item mobile-more-toggle')}</nav>`
    + `<div id="mobile-more-menu" class="mobile-more-menu" aria-label="More destinations"><div class="nav-group">${navigation.slice(4).map(([name, symbol]) => `<button class="nav-item${route.name === name ? ' active' : ''}" data-action="nav" data-route="${escape(name)}" aria-label="${escape(name)}"${route.name === name ? ' aria-current="page"' : ''}${disabled}>${icon(symbol)}<span>${escape(name)}</span></button>`).join('')}</div></div>` : '';
  const profile = `<button class="connection-button${tvSection === 'Connections' ? ' active tv-current' : ''}" data-action="nav" data-route="Connections" aria-label="Servers"${route.name === 'Connections' ? ' aria-current="page"' : ''}${disabled}><span class="avatar">${escape(account?.name.slice(0, 1).toUpperCase() ?? '+')}</span><span class="sr-only"><strong>${escape(account?.name ?? 'Your connection')}</strong><small>${escape(account?.serverName ?? 'Connect to Jellyfin')}</small></span></button>`;
  return `<div class="tv-bar"><span class="tv-brand"><img src="./brand/mark.svg" alt="" /><span>Reel</span></span><div class="tv-sections">${tabs}</div><div class="rail-bottom">${destination('Settings')}${profile}</div></div>`;
}

function syncMobileNavigation(): void {
  const menu = document.querySelector<HTMLElement>('#mobile-more-menu');
  // The phone tab bar and the TV tab bar both keep their extra destinations behind More.
  const mobile = layout === 'tv' || mobileNavigation.matches;
  if (!mobile) mobileMoreOpen = false;
  const expanded = mobile && mobileMoreOpen;
  if (menu) {
    menu.hidden = mobile && !expanded;
    if (expanded) { menu.setAttribute('role', 'dialog'); menu.setAttribute('aria-modal', 'true'); }
    else { menu.removeAttribute('role'); menu.removeAttribute('aria-modal'); }
  }
  document.querySelector('.mobile-more-toggle')?.setAttribute('aria-expanded', String(expanded));
  document.body.classList.toggle('more-open', expanded);
  content.inert = expanded || playing;
  document.querySelectorAll<HTMLElement>('.mobile-primary').forEach(group => group.toggleAttribute('inert', expanded));
  document.querySelector<HTMLElement>('#rail .brand')?.toggleAttribute('inert', expanded);
}

function showMobileMore(open: boolean, returnFocus = true): void {
  mobileMoreOpen = open && (layout === 'tv' || mobileNavigation.matches);
  syncMobileNavigation();
  if (mobileMoreOpen) document.querySelector<HTMLElement>('#mobile-more-menu .nav-item')?.focus();
  else if (returnFocus) document.querySelector<HTMLElement>('.mobile-more-toggle')?.focus({ preventScroll: true });
}
const navigationViewportChanged = () => {
  const activeInMenu = document.activeElement?.closest('#mobile-more-menu');
  const activeIsMore = document.activeElement?.matches('.mobile-more-toggle');
  mobileMoreOpen = false;
  // The sidebar and the tab bar order Search differently, so the rail is rebuilt at the breakpoint.
  rail();
  if (mobileNavigation.matches && activeInMenu) document.querySelector<HTMLElement>('.mobile-more-toggle')?.focus();
  else if (!mobileNavigation.matches && activeIsMore) document.querySelector<HTMLElement>('#rail .nav-item.active')?.focus();
};
const railViewportChanged = () => { applyRailState(); rail(); };
for (const [query, listener] of [[mobileNavigation, navigationViewportChanged], [tabletNavigation, railViewportChanged]] as const) {
  if (query.addEventListener) query.addEventListener('change', listener);
  else query.addListener(listener);
}
function toggleRail(): void {
  const next = document.documentElement.dataset.rail === 'collapsed' ? 'expanded' : 'collapsed';
  storage.setItem('reel.sidebar', next); applyRailState(); rail();
  document.querySelector<HTMLElement>('#rail .rail-toggle')?.focus();
}

function artworkHTML(item: MediaItem, shape: ArtworkShape = 'poster', width = 600, cls = ''): string {
  items.set(item.Id, item);
  return `<span class="artwork ${cls}"><span class="art-placeholder">${icon(item.Type === 'Series' ? 'live' : 'play')}</span><img data-art="${escape(item.Id)}" data-shape="${shape}" data-width="${width}" alt="" loading="lazy" /></span>`;
}
// One line of facts in the order every Reel client uses: year, rating badge, runtime (or "Series"), star
// rating, then sound and caption badges. Spacing and badges instead of a chain of separators.
function factsHTML(item: MediaItem, detailed = false): string {
  if (item.Type === 'Episode' && !detailed) return `<span>${escape(subtitle(item))}</span>`;
  const lead = item.Type === 'Episode' ? [item.SeriesName, episodeCode(item)] : [item.ProductionYear ? String(item.ProductionYear) : ''];
  const length = item.Type === 'Series' ? 'Series' : item.RunTimeTicks && Number.isFinite(item.RunTimeTicks) ? duration(item.RunTimeTicks / TICKS) : '';
  const rating = communityRating(item);
  const text = (part: string | undefined) => part ? `<span>${escape(part)}</span>` : '';
  return lead.map(text).join('')
    + (item.OfficialRating ? `<span class="badge">${escape(item.OfficialRating)}</span>` : '')
    + text(length)
    + (rating === undefined ? '' : `<span class="rating">${icon('star')}${rating.toFixed(1)}</span>`)
    + (detailed ? mediaBadges(item).map(badge => `<span class="badge">${escape(badge)}</span>`).join('') : '');
}
function card(item: MediaItem, wide = false, playDirectly = wide): string {
  const media = withPosition(item);
  const progress = viewingProgress(media);
  return `<button class="media-card ${wide ? 'wide-card' : ''}" data-action="${playDirectly ? 'play' : 'detail'}" data-id="${escape(media.Id)}"><span class="card-art">${artworkHTML(media, wide ? 'landscape' : 'poster', wide ? 800 : 500)}${playDirectly ? `<span class="card-play">${icon('play')}</span>` : ''}${progress ? `<span class="progress-track"><span style="width:${progress.percent}%"></span></span>` : ''}${media.UserData?.IsFavorite ? `<span class="favorite-mark">${icon('heart')}</span>` : ''}</span><strong>${escape(media.Type === 'Episode' ? media.SeriesName ?? media.Name : media.Name)}</strong><small>${escape(wide && progress && media.Type !== 'Episode' ? progress.remaining : subtitle(media))}</small></button>`;
}
function shelf(title: string, caption: string, media: MediaItem[], wide = false, key = '', playDirectly = wide): string {
  if (!media.length) return '';
  remember(media);
  return `<section class="shelf"${key ? ` data-shelf="${escape(key)}" aria-label="${escape(caption)}"` : ''}><header><h2>${escape(title)}</h2></header><div class="shelf-track">${media.map(item => card(item, wide, playDirectly)).join('')}</div></section>`;
}
function hydrate(): void { stopArt?.(); if (currentAPI) stopArt = artwork.observe(content, currentAPI, items); }
let stopTVConnectionForm: (() => void) | undefined;
function cleanupNoticeHTML(): string {
  const messages: Record<BrowseCleanupNotice['code'], string> = { preserved: 'Signed out. Existing browse choices were preserved because their ownership could not be verified.', io: 'Signed out. Some browse choices could not be removed from this device.', uncertain: 'Signed out. Removal of some browse choices could not be confirmed.' };
  const active = cleanupNotices.filter(notice => !dismissedCleanupNotices.has(notice.id));
  if (!active.length) return '';
  return `<section id="browse-cleanup-notice" class="browse-notice browse-cleanup" role="alert" aria-label="Browse cleanup warning"><div>${[...new Set(active.map(notice => notice.code))].map(code => `<p>${escape(messages[code])}</p>`).join('')}</div>${button('browse-dismiss-cleanup', 'Dismiss notice', undefined, 'button quiet')}</section>`;
}
desktopBrowse?.setNoticeHandler(notices => {
  cleanupNotices = notices; if (isClosing()) return;
  content.querySelector('#browse-cleanup-notice')?.remove(); content.insertAdjacentHTML('afterbegin', cleanupNoticeHTML());
});
// A TV remote has no pointer to find its place again, so re-rendering the same page keeps focus
// on the same control (or the first enabled one beside it while that control is busy).
let shownRoute: Route | undefined;
function focusIdentity(node: HTMLElement): string {
  if (node.id) return '#' + CSS.escape(node.id);
  // A menu's button (Watched, Audio and subtitles) is found again through its menu.
  if (node.matches('summary') && node.parentElement?.id) return `#${CSS.escape(node.parentElement.id)} > summary`;
  const action = node.dataset.action;
  return action ? `[data-action="${CSS.escape(action)}"]${node.dataset.id ? `[data-id="${CSS.escape(node.dataset.id)}"]` : ''}` : '';
}
// TV: a control that is busy for a moment (Favorite or Watched while the server answers) is disabled, so focus
// waits on a neighbour. If focus is still there at the next render, it goes back, so a second OK does not
// land on Play.
let busyFocus = '', busyHolder = '';
function show(html: string, focus = false): void {
  if (isClosing()) return;
  const active = document.activeElement;
  const identity = layout === 'tv' && shownRoute === route && active instanceof HTMLElement && content.contains(active) ? focusIdentity(active) : '';
  stopEpisodeArt?.(); stopEpisodeArt = undefined; content.style.minHeight = ''; stopTVConnectionForm?.(); stopTVConnectionForm = undefined; document.body.classList.remove('tv-connecting'); content.innerHTML = cleanupNoticeHTML() + html; hydrate();
  shownRoute = route;
  if (focus) restoreFocus(content);
  else if (identity) {
    const waiting = busyFocus && identity === busyHolder ? content.querySelector<HTMLButtonElement>(busyFocus) : null;
    const target = waiting && !waiting.disabled ? waiting : content.querySelector<HTMLElement>(identity);
    const usable = target && !(target as HTMLButtonElement).disabled ? target : target?.closest('.actions,.tv-row')?.querySelector<HTMLElement>('button:not([disabled])');
    if (!waiting?.disabled) [busyFocus, busyHolder] = target && target !== usable && usable ? [identity, focusIdentity(usable)] : ['', ''];
    usable?.focus({ preventScroll: true });
  }
  if (!identity) busyFocus = busyHolder = '';
}
function header(title: string, caption: string, extra = ''): string { return `<header class="page-header"><div>${caption ? `<span class="eyebrow">${escape(caption)}</span>` : ''}<h1>${escape(title)}</h1></div>${extra}</header>`; }
// Loading placeholders take the shape of the screen that is about to appear.
function loading(): void {
  const cards = (count: number) => '<span class="skeleton"></span>'.repeat(count);
  const shape = route.name === 'Home' ? `<span class="skeleton skeleton-hero skeleton-feature"></span><span class="skeleton skeleton-heading"></span><div class="skeleton-row">${cards(8)}</div>`
    : route.name === 'Details' ? `<span class="skeleton skeleton-hero"></span><span class="skeleton skeleton-heading"></span>`
    : `<span class="skeleton skeleton-heading"></span><div class="skeleton-grid">${cards(12)}</div>`;
  show(`<div class="loading-page" role="status"><h2 class="sr-only">Opening your library.</h2><div aria-hidden="true">${shape}</div></div>`);
}
function empty(title: string, message: string, action = ''): string { return `<div class="empty"><span class="empty-icon">${icon('library')}</span><h2>${escape(title)}</h2><p>${escape(message)}</p>${action}</div>`; }
function errorHTML(error: unknown): string { return empty('Let’s try that again.', error instanceof Error ? error.message : 'The server could not be reached.', button('retry', 'Try again', undefined, 'button primary') + button('connections', 'Manage servers', 'connection', 'button quiet')); }
function lockConnectionForm(form: HTMLFormElement | null, busy: boolean): void {
  if (!form) return;
  if (busy) {
    if (busyConnectionForms.has(form)) return;
    const previous = new Map<HTMLInputElement | HTMLButtonElement | HTMLSelectElement, boolean>();
    const controls = [...form.querySelectorAll<HTMLInputElement | HTMLButtonElement | HTMLSelectElement>('input,button,select'), ...document.querySelectorAll<HTMLButtonElement>('.saved-connections button,#saved-recovery button')];
    controls.forEach(control => { previous.set(control, control.disabled); control.disabled = true; });
    busyConnectionForms.set(form, previous);
  } else {
    busyConnectionForms.get(form)?.forEach((disabled, control) => { control.disabled = disabled; });
    busyConnectionForms.delete(form);
  }
}
function setConnectionBusy(busy: boolean): void {
  connectionCommit = busy;
  if (isClosing()) return;
  lockConnectionForm(document.querySelector<HTMLFormElement>('#connect-form'), busy);
  const status = document.querySelector<HTMLElement>('#connection-status'); if (status) status.hidden = !busy;
  if (!busy && connectionChangePending) { connectionChangePending = false; applyConnectionChange(); }
  else rail();
}
function recoverUncertainStore(error: unknown): boolean {
  if (!uncertainDesktopError(error)) return false;
  if (isClosing()) return true;
  routeGeneration++; playingId++; routeController.abort(); browser.close(); watchedActions.cancel(); void track(desktopBrowse?.activate(undefined) ?? Promise.resolve()); stopArt?.(); artwork.clear();
  if (searchTimer) { clearTimeout(searchTimer); searchTimer = undefined; }
  closePlayerExtras(); player.close(); playing = false; playerReturnRoute = undefined; presentation.close(); showFormat(false); void exitPlayerFullscreen(playerElement).catch(() => undefined); photoElement.hidden = true; document.querySelector('#photo-full')!.removeAttribute('src');
  content.removeAttribute('aria-hidden'); document.querySelector('#rail')!.removeAttribute('aria-hidden');
  show(empty('Quit and reopen Reel.', desktopError('uncertain').message), true); rail();
  return true;
}

async function navigate(next: Route, push = true, preserveDetail = false): Promise<void> {
  if (isClosing() || connectionCommit || desktop?.requiresReopen) return;
  browseFiltersExpanded = next.name === route.name && ['Library', 'Search', 'Favorites', 'Music', 'Photos', 'Books'].includes(route.name)
    ? content.querySelector<HTMLDetailsElement>('#browse-filter-panel')?.open ?? browseFiltersExpanded : false;
  if (searchTimer) { clearTimeout(searchTimer); searchTimer = undefined; }
  if (push && (route.name !== next.name || route.item !== next.item || route.parent !== next.parent)) {
    const homeControl = layout === 'tv' && route.name === 'Home' && document.activeElement instanceof HTMLElement && content.contains(document.activeElement)
      ? document.activeElement.closest<HTMLElement>('[data-action][data-id]') : null;
    const homeShelf = homeControl?.closest<HTMLElement>('.shelf');
    const homeFocus = homeControl?.dataset.id && homeControl.dataset.action ? {
      id: homeControl.dataset.id, action: homeControl.dataset.action, shelf: homeShelf?.querySelector('h2')?.textContent ?? '',
      offset: homeShelf?.querySelector<HTMLElement>('.shelf-track')?.scrollLeft ?? 0
    } : undefined;
    route = { ...route, scrollY: window.scrollY, ...(layout === 'tv' && route.name === 'Home' ? { homeFocus } : {}), ...(browser.state ? { focus: captureBrowseFocus(content) } : {}) };
    backStack.push(route);
  }
  browser.close(); watchedActions.cancel(); closeBrowseReset(); searchDraft++;
  if (next.name !== 'Connections') replaceSavedPending = false;
  route = next;
  homeEpisodeState = undefined;
  routeController.abort(); routeController = new AbortController();
  const generation = ++routeGeneration;
  const signal = routeController.signal;
  stopArt?.(); artwork.cancelPending();
  if (!connections.active && !['Connections', 'Settings'].includes(route.name)) route = { name: 'Connections' };
  rail();
  if (route.name === 'Connections') { renderConnections(); window.scrollTo(0, route.scrollY ?? 0); return; }
  if (route.name === 'Settings') { renderSettings(); window.scrollTo(0, route.scrollY ?? 0); settleTVFocus(); return; }
  loading();
  window.scrollTo(0, 0);
  try {
    if (route.name === 'Home') await home(generation, signal);
    else if (route.name === 'Details') {
      if (preserveDetail && detail && detail.Id === route.item) {
        if (seasonLoading && detail.Type === 'Series' && selectedSeason) {
          const season = selectedSeason, id = detail.Id;
          const page = await api().page(`Shows/${encodeURIComponent(id)}/Episodes`, { seasonId: season, isMissing: false }, signal);
          if (signal.aborted || generation !== routeGeneration || detail?.Id !== id || selectedSeason !== season) return;
          episodes = page.Items; remember(episodes); seasonLoading = false;
        }
        renderDetail();
      } else await details(route.item!, generation, signal);
    }
    else if (route.name === 'Live TV') await liveTV(generation, signal);
    else if (route.name === 'Devices') await devices(generation, signal);
    else await library();
  } catch (error) { if (!signal.aborted && generation === routeGeneration) show(errorHTML(error), true); }
  if (!signal.aborted && generation === routeGeneration) { window.scrollTo(0, route.scrollY ?? 0); settleTVFocus(); }
}
// TV: a page reached from content opens with its main control focused, so the remote always has a place.
function settleTVFocus(): void {
  const active = document.activeElement;
  if (layout !== 'tv') return;
  if (active instanceof HTMLElement && active !== document.body && active !== content && navigationVisible(active)) {
    // A restored scroll can come from the middle of a smooth row change; place the focused control again.
    if (content.contains(active)) revealTV(active);
    return;
  }
  const target = content.querySelector<HTMLElement>('.detail-intro .actions button:not([disabled]), .tv-key, .browse-results .media-card, .settings-panel select')
    ?? [...content.querySelectorAll<HTMLElement>('button:not([disabled]),select:not([disabled]),input:not([disabled]),[tabindex="0"]')].find(navigationVisible);
  target?.focus({ preventScroll: true });
}

function currentHomeEpisodes(state: HomeEpisodeState): boolean {
  return !isClosing() && homeEpisodeState === state && !state.signal.aborted && state.generation === routeGeneration && route.name === 'Home' && connections.active?.id === state.accountId && connections.active.token === state.accountToken;
}

function homeEpisodeSlot(state: HomeEpisodeState): string {
  const cards = state.media.length ? `<div class="shelf-track">${state.media.map(item => card(item, true, false)).join('')}</div>` : `<div class="shelf-track episode-skeleton" aria-hidden="true">${[0, 1, 2].map(() => '<div class="media-card wide-card"><span class="card-art"><span class="artwork"></span></span><strong>&nbsp;</strong><small>&nbsp;</small></div>').join('')}</div>`;
  // Refresh is a quiet icon beside See all; the TV row keeps its labelled button for the remote.
  const refresh = layout === 'tv' ? button('refresh-episodes', 'Refresh episodes', undefined, 'text-button') : button('refresh-episodes', 'Refresh episodes', 'refresh', 'icon-button episode-refresh');
  return `<section class="shelf" data-episode-slot${state.status === 'ready' && !state.media.length ? ' hidden' : ''}><header><h2>New episodes</h2>${button('browse-newest-episodes', 'See all episodes', undefined, 'text-button')}${refresh}</header><p class="episode-status" data-episode-status role="status"></p><div data-episode-body>${cards}</div></section>`;
}

function restoreHomeReturnFocus(): boolean {
  const remembered = route.homeFocus;
  if (!remembered) return false;
  const target = [...content.querySelectorAll<HTMLElement>('[data-action][data-id]')].find(node =>
    node.dataset.id === remembered.id && node.dataset.action === remembered.action &&
    (node.closest('.shelf')?.querySelector('h2')?.textContent ?? '') === remembered.shelf);
  if (!target) return false;
  const track = target.closest<HTMLElement>('.shelf-track');
  if (track) {
    track.scrollLeft = remembered.offset;
    const item = target.getBoundingClientRect(), frame = track.getBoundingClientRect();
    const left = Math.max(0, frame.left), right = Math.min(window.innerWidth, frame.right);
    track.scrollLeft += item.left < left ? item.left - left : item.right > right ? item.right - right : 0;
  }
  target.focus({ preventScroll: true });
  // The saved scroll can be from the middle of a smooth row change, so the row is pinned again.
  if (layout === 'tv') revealTV(target);
  return true;
}

function renderHomeEpisodes(state: HomeEpisodeState): void {
  if (!currentHomeEpisodes(state)) return;
  const slot = content.querySelector<HTMLElement>('[data-episode-slot]');
  if (!slot) return;
  const body = slot.querySelector<HTMLElement>('[data-episode-body]')!;
  const control = slot.querySelector<HTMLButtonElement>('[data-action="refresh-episodes"]')!;
  const status = slot.querySelector<HTMLElement>('[data-episode-status]')!;
  const focus = document.activeElement as HTMLElement | null;
  const focusedId = focus && body.contains(focus) ? focus.closest<HTMLElement>('[data-id]')?.dataset.id : undefined;
  const trackOffset = body.querySelector<HTMLElement>('.shelf-track')?.scrollLeft ?? 0;
  const scroll = { x: window.scrollX, y: window.scrollY };
  content.style.minHeight = Math.max(content.getBoundingClientRect().height, content.scrollHeight) + 'px';
  if (!body.style.minHeight && !slot.hidden) body.style.minHeight = Math.ceil(body.getBoundingClientRect().height) + 'px';
  const pending = state.status === 'loading';
  const label = state.status === 'error' ? 'Retry episodes' : 'Refresh episodes';
  control.setAttribute('aria-label', label);
  control.setAttribute('aria-disabled', String(pending));
  control.setAttribute('aria-busy', String(pending));
  control.querySelector('span')!.textContent = pending ? 'Loading episodes…' : label;
  status.setAttribute('role', state.status === 'error' ? 'alert' : 'status');
  status.textContent = pending ? 'Loading recent episodes.' : state.status === 'error' ? 'Episodes could not load.' : !state.media.length ? 'No recently added episodes.' : '';
  slot.hidden = state.status === 'ready' && !state.media.length && !state.explicitRefresh;
  if (state.media.length) slot.dataset.shelf = 'recent-episodes'; else slot.removeAttribute('data-shelf');
  if (state.status === 'ready') {
    remember(state.media);
    body.innerHTML = state.media.length ? `<div class="shelf-track">${state.media.map(item => card(item, true, false)).join('')}</div>` : '';
    stopEpisodeArt?.(); stopEpisodeArt = artwork.observe(body, state.api, items);
    const track = body.querySelector<HTMLElement>('.shelf-track');
    const clampOffset = (value: number): number => track ? Math.max(0, Math.min(value, track.scrollWidth - track.clientWidth)) : 0;
    if (track) track.scrollLeft = clampOffset(trackOffset);
    if (focusedId) {
      const retained = body.querySelector<HTMLElement>(`[data-id="${CSS.escape(focusedId)}"]`);
      (retained ?? control).focus({ preventScroll: true });
      if (retained && track) {
        // Order or item count can change. Keep the retained card within the actual
        // horizontal viewport without scrolling the document or another shelf.
        const cardBounds = retained.getBoundingClientRect(), trackBounds = track.getBoundingClientRect();
        const left = Math.max(0, trackBounds.left + track.clientLeft);
        const right = Math.min(window.innerWidth, trackBounds.left + track.clientLeft + track.clientWidth);
        const correction = cardBounds.left < left ? cardBounds.left - left : cardBounds.right > right ? cardBounds.right - right : 0;
        track.scrollLeft = clampOffset(track.scrollLeft + correction);
      }
    }
  } else if (state.status === 'error' && !state.media.length) {
    body.innerHTML = '';
  }
  window.scrollTo(scroll.x, scroll.y);
  if (state.returnFocusAnchor && state.status === 'ready') {
    if (document.activeElement === state.returnFocusAnchor) restoreHomeReturnFocus();
    state.returnFocusAnchor = undefined;
  }
}

async function refreshHomeEpisodes(state: HomeEpisodeState, explicit = false): Promise<void> {
  if (!currentHomeEpisodes(state) || state.status === 'loading') return;
  state.status = 'loading'; state.explicitRefresh ||= explicit;
  if (state.published) renderHomeEpisodes(state);
  try {
    const page = await state.api.recentEpisodes(state.signal);
    if (!currentHomeEpisodes(state)) return;
    state.media = page.Items; state.status = 'ready'; state.error = undefined;
  } catch (error) {
    if (!currentHomeEpisodes(state)) return;
    state.error = error; state.status = 'error';
  }
  if (state.published) renderHomeEpisodes(state);
}

function homeHero(item: MediaItem): string {
  return `${artworkHTML(item, 'backdrop', 1920, 'hero-art')}<div class="hero-shade"></div>${heroContent(item)}`;
}
function heroContent(item: MediaItem): string {
  const genre = item.Type === 'Episode' ? undefined : item.Genres?.[0];
  return `<div class="hero-content">${genre ? `<span class="eyebrow">${escape(genre)}</span>` : ''}<h1>${escape(item.Type === 'Episode' ? item.SeriesName ?? item.Name : item.Name)}</h1><p class="hero-meta">${factsHTML(item)}</p>${item.Overview ? `<p class="hero-overview">${escape(item.Overview)}</p>` : ''}<div class="actions">${item.Type !== 'Series' ? button('play', resumeSeconds(withPosition(item)) > 0 ? 'Resume' : 'Play', 'play', 'button primary', `data-id="${escape(item.Id)}"`) : ''}${button('detail', 'Details', undefined, item.Type === 'Series' ? 'button primary' : 'button glass', `data-id="${escape(item.Id)}"`)}</div></div>`;
}

// TV Home: the hero and the backdrop follow the focused card once focus settles.
let spotlightID = '', spotlightTimer: ReturnType<typeof setTimeout> | undefined, backdropRequest = 0;
function showTVBackdrop(item: MediaItem): void {
  const layer = content.querySelector<HTMLElement>('.tv-backdrop'), client = currentAPI;
  if (!layer || !client) return;
  const request = ++backdropRequest;
  void artwork.get(client, item, 'backdrop', 1920).then(url => {
    if (request !== backdropRequest || !layer.isConnected) return;
    const [first, second] = layer.querySelectorAll('img');
    const shown = first.classList.contains('is-shown') ? first : second.classList.contains('is-shown') ? second : null;
    if (shown?.getAttribute('src') === url) return;
    const next = shown === first ? second : first;
    const reveal = () => { if (request === backdropRequest) { next.classList.add('is-shown'); shown?.classList.remove('is-shown'); } };
    next.addEventListener('load', reveal, { once: true });
    next.src = url;
    if (next.complete && next.naturalWidth) reveal();
  }).catch(() => undefined);
}
function spotlightHome(id: string): void {
  const item = items.get(id), stage = content.querySelector<HTMLElement>('.tv-home .hero-stage');
  if (!item || !stage || route.name !== 'Home' || id === spotlightID) return;
  spotlightID = id;
  stage.querySelector('.hero-content')?.remove();
  stage.insertAdjacentHTML('beforeend', heroContent(item));
  fitTVHero();
  showTVBackdrop(item);
}
// A title that wraps to two lines takes the room of the genre and an overview line, so the spotlight never
// runs up under the tab bar.
function fitTVHero(): void {
  const hero = content.querySelector<HTMLElement>('.tv-home .hero-content'), title = hero?.querySelector('h1');
  if (!hero || !title) return;
  hero.classList.toggle('long-title', title.getBoundingClientRect().height > parseFloat(getComputedStyle(title).lineHeight) * 1.5);
}
content.addEventListener('focusin', event => {
  const home = layout === 'tv' && route.name === 'Home' ? content.querySelector<HTMLElement>('.tv-home') : null;
  if (!home) return;
  const target = event.target as HTMLElement, shelf = target.closest<HTMLElement>('.shelf');
  const rows = [...home.querySelectorAll<HTMLElement>('.shelf')].filter(row => !row.hidden);
  const index = shelf ? rows.indexOf(shelf) : -1;
  // Rows above the focused one fade out under the hero; the hero's own buttons answer Up only from the first row.
  home.dataset.row = String(index);
  rows.forEach((row, position) => row.classList.toggle('tv-passed', position < index));
  if (spotlightTimer) clearTimeout(spotlightTimer);
  const id = shelf ? target.closest<HTMLElement>('[data-id]')?.dataset.id : undefined;
  if (id) spotlightTimer = setTimeout(() => spotlightHome(id), 250);
});
// The TV tab bar steps aside once a page scrolls. It comes back with focus, or when a pointer such as
// LG's Magic Remote reaches the top of the screen.
if (layout === 'tv') {
  window.addEventListener('scroll', () => document.body.classList.toggle('tv-scrolled', window.scrollY > 4), { passive: true });
  window.addEventListener('pointermove', event => {
    const bar = document.querySelector<HTMLElement>('#rail');
    if (event.pointerType === 'mouse' && bar && event.clientY <= bar.offsetHeight) document.body.classList.remove('tv-scrolled');
  }, { passive: true });
}

function selectHomeFeature(id: string): void {
  const featured = homeFeatures.find(item => item.Id === id);
  const stage = content.querySelector<HTMLElement>('.hero-stage');
  if (!featured || !stage || route.name !== 'Home') return;
  homeFeaturedID = id; stage.innerHTML = homeHero(featured);
  content.querySelectorAll<HTMLElement>('[data-action="feature"]').forEach(control => control.setAttribute('aria-pressed', String(control.dataset.id === id)));
  hydrate();
}

function renderHomeBase(base: MediaItem[][], state: HomeEpisodeState, baseFailure: boolean): void {
  const [resume, next, movies, shows] = base;
  homeFeatures = featuredTitles(movies, shows, [...resume, ...next, ...state.media]);
  const featured = homeFeatures.find(item => item.Id === homeFeaturedID) ?? homeFeatures[0];
  homeFeaturedID = featured.Id;
  remember([...base.flat(), ...state.media]); state.published = true;
  const categories = `<nav class="home-categories" aria-label="Browse your library">${button('home-category', 'Movies', undefined, 'home-category', 'data-category="Movies"')}${button('home-category', 'Series', undefined, 'home-category', 'data-category="Series"')}${button('browse-newest-episodes', 'New episodes', undefined, 'home-category')}</nav>`;
  const selector = homeFeatures.length > 1 ? `<div class="feature-selector" aria-label="Featured titles">${homeFeatures.map(item => `<button class="feature-choice" data-action="feature" data-id="${escape(item.Id)}" aria-label="Feature ${escape(item.Name)}" aria-pressed="${item.Id === featured.Id}">${artworkHTML(item, 'backdrop', 240)}<span>${escape(item.Name)}</span></button>`).join('')}</div>` : '';
  // Phones have no sidebar, so Home carries the mark over its artwork, as on iPhone. Wider layouts hide it.
  const hero = `<section class="hero"><div class="home-brand" aria-hidden="true"><img src="./brand/mark.svg" alt="" /><span>Reel</span></div><div class="hero-stage">${homeHero(featured)}</div>${selector}</section>`;
  const notice = baseFailure ? '<div class="inline-notice">Some rows could not load. ' + button('retry', 'Retry', undefined, 'text-button') + '</div>' : '';
  const rows = `${shelf('Continue watching', 'Your place, saved', resume, true)}${shelf('Up next', 'The next episode', next, true, '', false)}${shelf('Recently added movies', 'Movie night', movies)}${homeEpisodeSlot(state)}${shelf('Recently added series', 'Find your next series', shows)}`;
  if (layout === 'tv') {
    // TV: the hero describes whatever is focused over a full-screen backdrop, and rows start in the lower half.
    // The tab bar replaces the category chips and the featured choices.
    show(`<div class="tv-home" data-row="-1"><div class="tv-backdrop" aria-hidden="true"><img alt="" /><img alt="" /></div><section class="hero" data-tv-pin="top"><div class="hero-stage">${homeHero(featured)}</div></section>${notice}${rows}</div>`);
    content.querySelectorAll<HTMLElement>('.tv-home .shelf').forEach(row => { row.dataset.tvPin = ''; });
    spotlightID = featured.Id; fitTVHero(); showTVBackdrop(featured);
  } else show(`${hero}${categories}${notice}${rows}<footer class="page-footer"><span>Reel</span><span>Your library, ready to play.</span></footer>`);
  renderHomeEpisodes(state);
  if (layout === 'tv' && (document.activeElement === document.body || document.activeElement === content) && !restoreHomeReturnFocus()) {
    const waiting = route.homeFocus?.shelf === 'New episodes' && state.status === 'loading'
      ? content.querySelector<HTMLElement>('[data-action="refresh-episodes"]') : null;
    if (waiting) { state.returnFocusAnchor = waiting; waiting.focus({ preventScroll: true }); }
    else content.querySelector<HTMLButtonElement>('.hero [data-action="play"], .hero [data-action="detail"]')?.focus({ preventScroll: true });
  }
}

async function home(generation: number, signal: AbortSignal): Promise<void> {
  const client = api();
  const state: HomeEpisodeState = { generation, signal, api: client, accountId: client.account!.id, accountToken: client.account!.token, status: 'ready', media: [], published: false, explicitRefresh: false };
  homeEpisodeState = state;
  const optional = refreshHomeEpisodes(state);
  const results = await Promise.allSettled([
    client.page('UserItems/Resume', { mediaTypes: 'Video', limit: 12 }, signal),
    client.page('Shows/NextUp', { limit: 12 }, signal),
    client.latest('Movie', signal), client.latest('Series', signal)
  ]);
  if (!currentHomeEpisodes(state)) return;
  const base = results.map(result => result.status === 'fulfilled' ? Array.isArray(result.value) ? result.value : result.value.Items : []);
  const failure = results.find(result => result.status === 'rejected');
  if (base.some(value => value.length)) { renderHomeBase(base, state, !!failure); return; }
  await optional;
  if (!currentHomeEpisodes(state)) return;
  if (state.media.length) { renderHomeBase(base, state, !!failure); return; }
  if (state.status === 'error') throw state.error;
  if (failure?.status === 'rejected') throw failure.reason;
  show(empty('A little quiet in here.', 'Movies, series and episodes will appear when they are added to your Jellyfin libraries.'));
}

function browseScope(): LibraryScope {
  const kinds: Record<string, LibraryScope['kind']> = { Library: 'library', Search: 'search', Favorites: 'favorites', Music: 'music', Photos: 'photos', Books: 'books' };
  const category: LibraryCategory = libraryCategories.includes(route.filter as LibraryCategory) ? route.filter as LibraryCategory : 'All';
  return { kind: route.parent ? 'container' : kinds[route.name] ?? 'library', category,
    libraryId: route.library ?? '', parentId: route.parent ?? '', parentType: route.parentType ?? (route.parent ? items.get(route.parent)?.Type ?? 'Folder' : '') };
}
const browseOwner = () => `${connections.revision}|${connections.activeId}|${routeGeneration}`;
async function library(): Promise<void> {
  const account = connections.active; if (!account) return;
  const provider = api(), scope = browseScope(), generation = routeGeneration;
  const title = scope.parentId ? items.get(scope.parentId)?.Name ?? 'Library' : route.intent === 'newest-episodes' ? 'New episodes' : route.name;
  await browser.open({ account: { server: account.server, userId: account.userId }, owner: browseOwner(), scope,
    query: route.query ?? '', title, session: String(connections.revision), restore: route.scrollY !== undefined, clearFilters: route.clearFilters, newestEpisodes: route.intent === 'newest-episodes' }, provider);
  if (generation !== routeGeneration) return;
  route.clearFilters = undefined;
  if (route.scrollY !== undefined) window.scrollTo(0, route.scrollY);
  if (route.focus) { const restored = restoreBrowseFocus(content, route.focus); if (restored === 'removed') toast('That title is no longer in this view.'); }
  else if (route.focusId) content.querySelectorAll<HTMLElement>('[id]').forEach(node => { if (node.id === route.focusId) node.focus({ preventScroll: true }); });
  else if (route.name === 'Search') content.querySelector<HTMLInputElement>('#search')?.focus({ preventScroll: true });
}
// TV Search types with an on-screen keyboard, so a five-way remote never needs the system keyboard.
const tvKeys = [...'abcdefghijklmnopqrstuvwxyz1234567890'];
function tvKeyboard(query: string): string {
  const key = (value: string, label: string, index: number, wide = false) => `<button class="tv-key${wide ? ' wide' : ''}" id="tv-key-${index}" data-action="tv-key" data-key="${escape(value)}" aria-label="${escape(label)}">${escape(label)}</button>`;
  return `<div class="tv-keyboard" role="group" aria-label="Keyboard"><p class="tv-query">${icon('search')}<span data-placeholder="Movies, series and episodes">${escape(query)}</span></p><div class="tv-keys">${tvKeys.map((value, index) => key(value, value, index)).join('')}${key(' ', 'Space', 36, true)}${key('delete', 'Delete', 37, true)}${key('clear', 'Clear', 38, true)}</div></div>`;
}
function typeSearch(value: string): void {
  const input = content.querySelector<HTMLInputElement>('#search');
  if (!input) return;
  input.value = value === 'delete' ? input.value.slice(0, -1) : value === 'clear' ? '' : input.value + value;
  content.querySelector('.tv-query span')!.textContent = input.value;
  input.dispatchEvent(new Event('input', { bubbles: true }));
}
function renderBrowse(): void {
  const state = browser.state; if (!state || state.entry.owner !== browseOwner() || isClosing()) return;
  const captured = captureBrowseFocus(content), scroll = { x: window.scrollX, y: window.scrollY };
  remember(state.page.items);
  browseFiltersExpanded = content.querySelector<HTMLDetailsElement>('#browse-filter-panel')?.open ?? browseFiltersExpanded;
  // A view opened from the navigation is a root: phones and tablets drop its Back button, like any tab.
  const root = !route.parent && route.intent !== 'newest-episodes';
  show(libraryHTML(state, api().protected, item => artworkHTML(item, 'poster', state.choices.view === 'list' ? 180 : 500), browseFiltersExpanded, layout === 'tv' ? tvKeyboard(state.entry.query) : '', root));
  syncFilterSheet();
  window.scrollTo(scroll.x, scroll.y);
  if (restoreBrowseFocus(content, captured) === 'removed') toast('That title is no longer in this view.');
}
browser.onChange = renderBrowse;
function syncWatchedDialog(): void {
  const previous = document.querySelector<HTMLElement>('#browse-watched-layer');
  const activeAction = previous?.contains(document.activeElement) ? (document.activeElement as HTMLElement).dataset.action : undefined;
  previous?.remove();
  if (!watchedActions.plan) {
    if (!playing && photoElement.hidden) { content.removeAttribute('aria-hidden'); document.querySelector('#rail')!.removeAttribute('aria-hidden'); }
    if (dialogReturnFocus?.isConnected) dialogReturnFocus.focus({ preventScroll: true });
    else restoreBrowseFocus(content, dialogReturnIdentity);
    dialogReturnFocus = null; return;
  }
  const layer = document.createElement('div'); layer.id = 'browse-watched-layer'; layer.innerHTML = renderWatchedDialog(watchedActions); app.append(layer);
  layer.addEventListener('keydown', event => {
    const dialog = layer.querySelector<HTMLElement>('[role="dialog"]')!;
    if (['Tab', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)
      && !dialog.querySelector('button:not([disabled]),input:not([disabled]),select:not([disabled]),[tabindex="0"]')) {
      event.preventDefault(); event.stopPropagation(); dialog.focus({ preventScroll: true });
    }
  });
  content.setAttribute('aria-hidden', 'true'); document.querySelector('#rail')!.setAttribute('aria-hidden', 'true');
  const target = [...layer.querySelectorAll<HTMLButtonElement>('button:not([disabled])')].find(node => node.dataset.action === activeAction) ?? layer.querySelector<HTMLButtonElement>('button:not([disabled])');
  (target ?? layer.querySelector<HTMLElement>('[role="dialog"]'))?.focus({ preventScroll: true });
}
watchedActions.onChange = syncWatchedDialog;
function prepareWatched(selectedItems: MediaItem[], value: boolean): void {
  detailStatusRead++;
  const provider = api(), owner = browseOwner();
  dialogReturnFocus = document.activeElement as HTMLElement; dialogReturnIdentity = captureBrowseFocus(content);
  const account = { server: provider.server, userId: provider.account!.userId };
  watchedActions.prepare(selectedItems, value, { owner, protected: provider.protected, current: browseOwner, onAccepted: () => browser.invalidateAccount(account, !(watchedActions.busy && owner === browseOwner())),
    write: (item, watched, signal) => provider.request(`UserPlayedItems/${encodeURIComponent(item.Id)}`, { method: watched ? 'POST' : 'DELETE', query: { userId: provider.account?.userId }, signal }) });
}
let resetOwner = '';
let resetReturn: HTMLElement | null = null;
function showBrowseReset(): void {
  if (!browser.state?.preferences.canReset) return;
  closeBrowseReset(); resetOwner = browseOwner(); resetReturn = document.activeElement as HTMLElement;
  const layer = document.createElement('div'); layer.id = 'browse-reset-layer';
  layer.innerHTML = `<div class="browse-modal-backdrop"><section id="browse-reset-dialog" class="browse-modal" role="dialog" aria-modal="true" aria-labelledby="browse-reset-title"><h2 id="browse-reset-title">Reset saved browse choices?</h2><p>Only browse choices for ${escapeBrowse(connections.active?.name)} on ${escapeBrowse(connections.active?.serverName)} will be removed. Connections and media stay in place. This cannot undo changes already made on Jellyfin.</p><div class="actions">${button('browse-reset-cancel', 'Cancel')}${button('browse-reset-confirm', 'Reset choices', undefined, 'button primary')}</div></section></div>`;
  app.append(layer); content.setAttribute('aria-hidden', 'true'); document.querySelector('#rail')!.setAttribute('aria-hidden', 'true'); restoreFocus(layer);
}
function closeBrowseReset(): void {
  const layer = document.querySelector('#browse-reset-layer'); if (!layer) return;
  layer.remove(); content.removeAttribute('aria-hidden'); document.querySelector('#rail')!.removeAttribute('aria-hidden');
  if (resetReturn?.isConnected) resetReturn.focus({ preventScroll: true }); resetReturn = null;
}
async function finishWatchedDialog(): Promise<void> {
  const changed = watchedActions.acceptedItems.length > 0, focus = dialogReturnIdentity, returnOwner = browseOwner();
  watchedActions.cancel();
  if (!changed) return;
  if (browser.state) await browser.load('refresh');
  else if (route.name === 'Details' && detail) {
    const provider = api(), owner = browseOwner(), signal = routeController.signal, statusRead = ++detailStatusRead;
    try {
      await refreshWatchedDetail({ signal,
        current: () => !isClosing() && statusRead === detailStatusRead && browseOwner() === owner && route.name === 'Details' && detail && route.item === detail.Id
          ? { owner, item: detail, season: selectedSeason, episodes } : undefined,
        readItem: (id, signal) => provider.item(id, signal),
        readSeason: (id, season, signal) => provider.page(`Shows/${encodeURIComponent(id)}/Episodes`, { seasonId: season, isMissing: false }, signal),
        publish: state => { detail = state.item; episodes = [...state.episodes]; remember([detail, ...episodes]); renderDetail(); }
      });
    } catch (error) {
      if (!signal.aborted && statusRead === detailStatusRead && browseOwner() === owner) throw new ApiError('Watched changes were accepted, but their current status could not be refreshed. ' + (error instanceof Error ? error.message : 'Try opening this title again.'));
    }
    // Marking a series or a season moves its next episode, which the first action names.
    const series = detail;
    if (series?.Type === 'Series') {
      const found = await readNextUp(series.Id, signal);
      if (!isClosing() && !signal.aborted && detail?.Id === series.Id) { nextUp = found; if (found) remember([found]); renderDetail(); }
    }
  }
  if (browseOwner() === returnOwner) restoreBrowseFocus(content, focus);
}

async function details(id: string, generation: number, signal: AbortSignal): Promise<void> {
  const fetched = await api().item(id, signal);
  if (isClosing() || signal.aborted || generation !== routeGeneration) return;
  const item = withPosition(fetched);
  let loadedSeasons: MediaItem[] = [], loadedEpisodes: MediaItem[] = [], initialSeason = '', loadedNextUp: MediaItem | undefined;
  if (item.Type === 'Series') {
    const upcoming = readNextUp(id, signal);
    const page = await api().page(`Shows/${encodeURIComponent(id)}/Seasons`, {}, signal);
    if (isClosing() || signal.aborted || generation !== routeGeneration) return;
    loadedSeasons = page.Items; initialSeason = loadedSeasons[0]?.Id ?? '';
    if (initialSeason) {
      const page = await api().page(`Shows/${encodeURIComponent(id)}/Episodes`, { seasonId: initialSeason, isMissing: false }, signal);
      if (isClosing() || signal.aborted || generation !== routeGeneration) return;
      loadedEpisodes = page.Items;
    }
    loadedNextUp = await upcoming;
  }
  if (isClosing() || signal.aborted || generation !== routeGeneration) return;
  detail = item; selectedMediaSource = item.MediaSources?.[0]?.Id ?? ''; selectedAudio = ''; selectedSubtitle = ''; trackMenuOpen = false;
  seasonLoading = false; seasons = loadedSeasons; selectedSeason = initialSeason; episodes = loadedEpisodes; similarItems = []; nextUp = loadedNextUp;
  remember(loadedNextUp ? [item, loadedNextUp] : [item]); renderDetail();
  if (layout !== 'tv' && (item.Type === 'Movie' || item.Type === 'Series')) void loadSimilar(item.Id, generation, signal);
}

// The episode a series continues with. Some servers answer for every series at once, so the answer is
// matched to this one; no answer leaves Episodes as the first action.
async function readNextUp(seriesId: string, signal: AbortSignal): Promise<MediaItem | undefined> {
  const page = await api().page('Shows/NextUp', { seriesId, limit: 1 }, signal).catch(() => undefined);
  return (Array.isArray(page?.Items) ? page.Items : []).find(entry => entry?.SeriesId === seriesId && typeof entry.Id === 'string');
}

// More like this arrives after Details is on screen. A server that does not answer, or answers late for a
// title already left, leaves the page as it is.
async function loadSimilar(id: string, generation: number, signal: AbortSignal): Promise<void> {
  const page = await api().page(`Items/${encodeURIComponent(id)}/Similar`, { limit: 12 }, signal).catch(() => undefined);
  if (!page || isClosing() || signal.aborted || generation !== routeGeneration || detail?.Id !== id) return;
  similarItems = (Array.isArray(page.Items) ? page.Items : []).filter(entry => typeof entry?.Id === 'string' && entry.Id !== id && typeof entry.Name === 'string');
  const body = content.querySelector<HTMLElement>('.detail-body');
  if (!similarItems.length || !body || body.querySelector('[data-shelf="similar"]')) return;
  const cast = body.querySelector('.cast');
  if (cast) cast.insertAdjacentHTML('beforebegin', similarHTML()); else body.insertAdjacentHTML('beforeend', similarHTML());
  hydrate();
}
function similarHTML(): string { return shelf('More like this', 'More like this', similarItems, false, 'similar'); }

function renderDetail(): void {
  if (isClosing() || !detail) return;
  const item = withPosition(detail), source = item.MediaSources?.find(source => source.Id === selectedMediaSource) ?? item.MediaSources?.[0];
  const isFolder = isAggregateItem(item);
  const tracks = (source?.MediaStreams ?? []).filter(stream => Number.isSafeInteger(stream.Index) && stream.Index >= 0);
  const audio = tracks.filter(stream => stream.Type === 'Audio');
  const subtitles = tracks.filter(stream => stream.Type === 'Subtitle');
  const playAction = item.Type === 'Photo' ? 'photo' : item.Type === 'Book' ? 'book' : isFolder ? 'browse-folder' : 'play';
  const disabled = (kind: string) => kind === 'watched' && !supportsWatchedMutation(item) ? ' disabled title="' + escape(watchedUnavailableReason(item)) + '"' : api().protected ? ' disabled title="Changes to the server are off in view-only mode"' : pendingMutations.has(mutationKey(kind, item.Id)) ? ' disabled aria-busy="true"' : '';
  const resumable = resumeSeconds(item) > 0 && !isFolder && !['Series', 'Book', 'Photo'].includes(item.Type ?? '');
  const progress = resumable ? viewingProgress(item) : undefined;
  const primaryLabel = isFolder ? 'Open collection' : item.Type === 'Book' ? pendingMutations.has(mutationKey('book', item.Id)) ? 'Downloading…' : 'Download book' : item.Type === 'Photo' ? 'View photo' : resumable ? 'Resume' : 'Play';
  const primaryState = item.Type === 'Book' ? api().protected ? ' disabled title="Downloads are off in view-only mode"' : pendingMutations.has(mutationKey('book', item.Id)) ? ' disabled aria-busy="true"' : '' : '';
  // A series leads with its next episode, named ("Resume S1 E2"); without one, Episodes leads.
  const upcoming = item.Type === 'Series' && nextUp ? withPosition(nextUp) : undefined;
  const upcomingProgress = upcoming ? viewingProgress(upcoming) : undefined;
  const upcomingLabel = upcoming ? `${upcomingProgress ? 'Resume' : 'Play'} ${episodeCode(upcoming) || upcoming.Name}` : '';
  const playButton = item.Type === 'Series'
    ? upcoming ? `<button class="button primary" data-action="play" aria-label="${escape(upcomingLabel)}" data-id="${escape(upcoming.Id)}">${icon('play')}<span>${escape(upcomingLabel)}</span>${upcomingProgress ? `<small class="button-detail">${escape(upcomingProgress.remaining)}</small>` : ''}</button>`
      : seasons.length ? button('tv-episodes', 'Episodes', 'library', 'button primary') : ''
    : `<button class="button primary" data-action="${playAction}" aria-label="${escape(primaryLabel)}" data-id="${escape(item.Id)}"${primaryState}>${icon('play')}<span>${escape(primaryLabel)}</span>${progress ? `<small class="button-detail">${escape(progress.remaining)}</small>` : ''}</button>`;
  const favorite = item.UserData?.IsFavorite === true, watched = itemWatched(item);
  const genres = item.Type === 'Episode' ? undefined : item.Genres?.[0];
  const overview = item.Overview ? `<p class="detail-overview" id="detail-overview">${escape(item.Overview)}</p>${button('overview-more', 'Read more', undefined, 'text-button overview-more', 'aria-controls="detail-overview" aria-expanded="false" hidden')}` : '';
  const notes = (!supportsWatchedMutation(item) ? `<p class="field-note">${escape(watchedUnavailableReason(item))}</p>` : '')
    + (api().protected ? `<p class="protection-note">${icon('shield')}<span>View only: watching here does not change watch history, favorites, playlists or downloads on the server.</span></p>` : '');
  const watchedIcon = icon('check').replace('<svg', `<svg class="${watched === true ? 'is-on' : ''}"`);
  // A title with a known state toggles in place. A series, a season or a mixed state has a scope, so one
  // Watched button opens both choices and the confirmation names what changes.
  const togglesWatched = isKnownLeafItem(item) && watched !== undefined;
  const watchedControl = togglesWatched || disabled('watched')
    ? `<button class="button glass" data-action="watched" aria-pressed="${watched === true}"${disabled('watched')}>${watchedIcon}<span>Watched</span></button>`
    : `<details class="detail-menu" id="watched-menu"><summary class="button glass" tabindex="0">${watchedIcon}<span>Watched</span></summary><div class="detail-menu-panel"><h2 class="sheet-title" aria-hidden="true">Watched</h2>${button('watched-mark', watchedActionLabel([item], true), 'check', 'button quiet', 'data-value="true"')}${button('watched-mark', watchedActionLabel([item], false), 'close', 'button quiet', 'data-value="false"')}</div></details>`;
  // Audio, subtitles and version sit behind one compact control; a series leaves them to its episodes.
  const trackFields = isFolder || item.Type === 'Series' ? '' : `${audio.length ? `<label>Audio<select id="audio-track"><option value=""${selected(selectedAudio, '')}>Server default</option>${audio.map(stream => `<option value="${escape(stream.Index)}"${selected(selectedAudio, String(stream.Index))}>${escape(stream.DisplayTitle ?? stream.Language ?? 'Track ' + stream.Index)}</option>`).join('')}</select></label>` : ''}${subtitles.length ? `<label>Subtitles<select id="subtitle-track"><option value=""${selected(selectedSubtitle, '')}>Server default</option><option value="-1"${selected(selectedSubtitle, '-1')}>Off</option>${subtitles.map(stream => `<option value="${escape(stream.Index)}"${selected(selectedSubtitle, String(stream.Index))}>${escape(stream.DisplayTitle ?? stream.Language ?? 'Track ' + stream.Index)}</option>`).join('')}</select></label>` : ''}${(item.MediaSources?.length ?? 0) > 1 ? `<label>Version<select id="media-source">${item.MediaSources!.map((media, index) => `<option value="${escape(media.Id)}"${selected(selectedMediaSource, media.Id)}>Version ${index + 1} · ${escape(media.Container ?? '')}</option>`).join('')}</select></label>` : ''}`;
  const trackLabel = audio.length || subtitles.length ? 'Audio and subtitles' : 'Version';
  // Phones show a one-word label in the icon row; the full name stays the control's accessible name.
  const trackShortLabel = audio.length || subtitles.length ? 'Languages' : 'Version';
  // Read the menu's state from the page being replaced, so a choice made right after opening keeps it open.
  const shownTrackMenu = content.querySelector<HTMLDetailsElement>('#track-menu');
  if (shownTrackMenu?.dataset.id === item.Id) trackMenuOpen = shownTrackMenu.open;
  const trackMenu = trackFields ? `<details class="detail-menu track-menu" id="track-menu" data-id="${escape(item.Id)}"${trackMenuOpen ? ' open' : ''}><summary class="button glass" tabindex="0" aria-label="${trackLabel}">${icon('captions')}<span class="label-full">${trackLabel}</span><span class="label-short" aria-hidden="true">${trackShortLabel}</span></summary><div class="detail-menu-panel track-options"><h2 class="sheet-title" aria-hidden="true">${trackLabel}</h2>${trackFields}</div></details>` : '';
  remember(episodes);
  show(`<section class="detail-hero${item.Type === 'Series' ? ' detail-series' : ''}">${artworkHTML(item, 'backdrop', 1920)}<div class="detail-shade"></div>${button('back', 'Back', 'back', 'button glass detail-back')}<div class="detail-intro">${artworkHTML(item, 'poster', 600, 'detail-poster')}<div class="detail-heading">${genres ? `<span class="eyebrow">${escape(genres)}</span>` : ''}<h1>${escape(item.Name)}</h1><p class="hero-meta">${factsHTML(item, true)}</p>${overview}<div class="actions">${playButton}${resumable ? button('start-over', 'Restart', 'restart', 'button glass', `data-id="${escape(item.Id)}"`) : ''}${layout === 'tv' && upcoming && seasons.length ? button('tv-episodes', 'Episodes', 'library', 'button glass') : ''}<button class="button glass" data-action="favorite" aria-pressed="${favorite}"${disabled('favorite')}>${icon('heart').replace('<svg', `<svg class="${favorite ? 'is-on' : ''}"`)}<span>Favorite</span></button>${watchedControl}${trackMenu}</div></div></div></section><section class="detail-body"><div class="detail-notes">${notes}</div>${item.Type === 'Series' ? `<section class="episodes" data-tv-group>${layout === 'tv'
    // TV: seasons are a row of tabs above a row of episode cards.
    ? `<header><h2>Episodes</h2></header><div class="season-tabs tv-row" role="group" aria-label="Seasons"${seasonLoading ? ' aria-busy="true"' : ''}>${seasons.map(season => button('season-tab', season.Name, undefined, 'season-tab', `data-id="${escape(season.Id)}" aria-pressed="${season.Id === selectedSeason}"`)).join('')}</div>`
    : `<header><h2>Episodes</h2><label>Season<select id="season"${seasonLoading ? ' disabled' : ''}>${seasons.map(season => `<option value="${escape(season.Id)}"${selected(selectedSeason, season.Id)}>${escape(season.Name)}</option>`).join('')}</select></label></header>`}${seasonLoading ? `<div class="season-loading" role="status"><span class="sr-only">Opening this season.</span><div class="episode-grid" aria-hidden="true">${'<span class="skeleton episode-skeleton-card"></span>'.repeat(Math.max(2, Math.min(episodes.length, 8)))}</div></div>` : episodes.length ? `<div class="episode-grid${layout === 'tv' ? ' tv-row' : ''}">${episodes.map(episode => episodeRow(episode)).join('')}</div>` : '<p>No episodes are available in this season.</p>'}</section>` : ''}${similarHTML()}${item.People?.length ? `<section class="cast"><h2>Cast & crew</h2><div>${item.People.slice(0, 18).map(person => `<article><strong>${escape(person.Name)}</strong><small>${escape(person.Role ?? person.Type ?? '')}</small></article>`).join('')}</div></section>` : ''}</section>`);
  // Offer "Read more" only when the clamp actually hides text at this width.
  const overviewNode = content.querySelector<HTMLElement>('#detail-overview'), more = content.querySelector<HTMLElement>('[data-action="overview-more"]');
  if (overviewNode && more) more.hidden = overviewNode.scrollHeight <= overviewNode.clientHeight + 1;
}

function episodeRow(episode: MediaItem): string {
  const item = withPosition(episode), progress = viewingProgress(item);
  const number = Number.isSafeInteger(item.IndexNumber) && item.IndexNumber! >= 0 ? `${item.IndexNumber}. ` : '';
  const played = item.UserData?.Played === true;
  // One muted line: the time left on a started episode, otherwise its runtime, then Watched.
  const metadata = [progress?.remaining ?? (item.RunTimeTicks && Number.isFinite(item.RunTimeTicks) ? duration(item.RunTimeTicks / TICKS) : 'Episode'), played ? 'Watched' : ''].filter(Boolean);
  return `<article class="episode-row" data-id="${escape(item.Id)}"><button class="episode-main" data-action="detail" data-id="${escape(item.Id)}" aria-label="Details for ${escape(item.Name)}"><span class="episode-art">${artworkHTML(item, 'landscape', 500)}${progress ? `<span class="episode-progress"><span style="width:${progress.percent}%"></span></span>` : ''}${played ? `<span class="watched-mark">${icon('check')}</span>` : ''}</span><span class="episode-copy"><strong>${escape(number + item.Name)}</strong><small>${metadata.map(part => `<span>${escape(part)}</span>`).join('')}</small>${item.Overview ? `<p>${escape(item.Overview)}</p>` : ''}</span></button>${button('play', `${progress ? 'Resume' : 'Play'} ${item.Name}`, 'play', 'button quiet episode-play', `data-id="${escape(item.Id)}"`)}</article>`;
}

async function downloadBook(id: string): Promise<void> {
  if (isClosing()) return;
  if (api().protected) throw new ApiError('Book downloads are disabled in protected preview.');
  const revision = connections.revision, generation = routeGeneration, signal = routeController.signal, name = items.get(id)?.Name ?? 'Book';
  const key = mutationKey('book', id); if (pendingMutations.has(key)) return;
  pendingMutations.add(key); renderDetail();
  try {
    const response = await api().request<Response>(`Items/${encodeURIComponent(id)}/Download`, { raw: true, signal });
    const blob = await readBlob(response, 128 * 1024 * 1024, signal);
    if (isClosing() || revision !== connections.revision || generation !== routeGeneration) return;
    const url = URL.createObjectURL(blob), link = document.createElement('a');
    link.href = url; link.download = name; link.click(); setTimeout(() => URL.revokeObjectURL(url), 60000);
  } finally {
    pendingMutations.delete(key);
    if (!isClosing() && revision === connections.revision && route.name === 'Details' && route.item === id && detail?.Id === id && content.querySelector('.detail-intro')) renderDetail();
  }
}

async function mutateDetail(kind: 'favorite' | 'watched'): Promise<void> {
  if (isClosing()) return;
  const item = detail;
  if (!item) return;
  const itemAccount = connections.active; if (!itemAccount) return;
  const key = mutationKey(kind, item.Id), revision = connections.revision, generation = routeGeneration;
  if (pendingMutations.has(key)) return;
  if (kind === 'watched') detailStatusRead++;
  pendingMutations.add(key); renderDetail();
  const stillCurrent = () => !isClosing() && revision === connections.revision && generation === routeGeneration && detail?.Id === item.Id;
  try {
    if (api().protected) throw new ApiError('Protected preview blocks library changes.');
    if (kind === 'favorite') await api().favorite(item, !item.UserData?.IsFavorite);
    else { if (!isKnownLeafItem(item) || itemWatched(item) === undefined) throw new ApiError('Confirm this watched change first.'); await api().watched(item, itemWatched(item) !== true); }
    browser.invalidateAccount({ server: itemAccount.server, userId: itemAccount.userId });
    if (!stillCurrent() || !detail) return;
    detail = { ...detail, UserData: { ...detail.UserData, ...(kind === 'favorite' ? { IsFavorite: !item.UserData?.IsFavorite } : { Played: itemWatched(item) !== true }) } };
    remember([detail]);
  } finally {
    pendingMutations.delete(key);
    if (stillCurrent()) renderDetail();
    else if (!isClosing() && revision === connections.revision && route.name === 'Details' && route.item === item.Id) await navigate(route, false);
  }
}

async function playItem(id: string, fromStart = false): Promise<void> {
  if (isClosing()) return;
  cancelAutoNext();
  if (playing) autoNextCancelled = true;
  playerTransitionPending = true;
  const generation = ++playingId;
  const account = connections.active;
  const initiator = document.activeElement as HTMLElement | null;
  if (!account) { playerTransitionPending = false; return; }
  try {
    const item = withPosition(await api().item(id));
    if (isClosing() || generation !== playingId || account.id !== connections.active?.id) return;
    const options = { bitrate: quality, start: fromStart ? 0 : resumeSeconds(item), audio: detail?.Id === id && selectedAudio ? Number(selectedAudio) : undefined, subtitle: detail?.Id === id && selectedSubtitle ? Number(selectedSubtitle) : undefined, source: (detail?.Id === id && playbackSources(item).some(source => source.Id === selectedMediaSource) ? selectedMediaSource : playbackSources(item)[0]?.Id) };
    if (!playing) playerReturnRoute = { ...route, scrollY: window.scrollY, focus: captureBrowseFocus(content), focusItem: initiator?.dataset.id, playerFocus: initiator?.classList.contains('episode-play') ? 'episode-play' : undefined };
    closePlayerExtras();
    playing = true; currentPlayingItem = item; playbackSelection = options; playbackChange = undefined; scrubbing = false;
    document.querySelector<HTMLDetailsElement>('.playback-details')!.open = false; showFormat(false); selectPlayerPanel('options'); presentation.open();
    updateEpisodeControls();
    document.querySelector('#player-title')!.textContent = item.Type === 'Episode' ? item.SeriesName ?? item.Name : item.Name;
    document.querySelector('#player-subtitle')!.textContent = subtitle(item);
    nextEpisode = undefined;
    const chapters = (item.Chapters ?? []).filter(chapter => typeof chapter.StartPositionTicks === 'number' && Number.isFinite(chapter.StartPositionTicks) && chapter.StartPositionTicks >= 0);
    document.querySelector<HTMLElement>('#chapters-label')!.hidden = !chapters.length;
    document.querySelector('#chapters')!.innerHTML = chapters.map((chapter, index) => `<option value="${chapter.StartPositionTicks / TICKS}">${escape(chapter.Name ?? `Chapter ${index + 1}`)}</option>`).join('');
    playbackGeneration = generation;
    void player.open(api(), item, options);
    void track(loadPlayerExtras(item, generation));
  } catch (error) { if (!isClosing() && generation === playingId && account.id === connections.active?.id && account.token === connections.active?.token) { playerTransitionPending = false; toast(error instanceof Error ? error.message : 'This title could not be played.'); } }
}

function restorePlayerReturnFocus(returning: Route): void {
  const candidates = [...content.querySelectorAll<HTMLElement>('[data-action]')];
  const target = returning.playerFocus && returning.focusItem ? candidates.find(node => node.classList.contains(returning.playerFocus!) && node.dataset.id === returning.focusItem) : returning.focusItem && returning.focus?.action ? candidates.find(node => node.dataset.id === returning.focusItem && node.dataset.action === returning.focus?.action) : undefined;
  if (target && !target.hasAttribute('disabled')) target.focus({ preventScroll: true });
  else if (restoreBrowseFocus(content, returning.focus) === 'none') restoreFocus(content);
}

async function closePlayer(): Promise<void> {
  const closing = ++playingId; closePlayerExtras(); player.close(); showFormat(false);
  try { await exitPlayerFullscreen(playerElement); }
  catch {
    if (closing !== playingId || isClosing()) return;
    if (document.fullscreenElement && playerElement.contains(document.fullscreenElement)) {
      toast('Could not leave full screen. Use Exit full screen or try Close again.');
      return;
    }
  }
  if (closing !== playingId || isClosing()) return;
  playing = false; presentation.close();
  if (route.name === 'Details' && detail) renderDetail();
  else await navigate(playerReturnRoute ?? route, false);
  if (playerReturnRoute) restorePlayerReturnFocus(playerReturnRoute); else restoreFocus(content);
  playerReturnRoute = undefined;
}

function renderSavedRecovery(): void {
  const panel = document.querySelector<HTMLElement>('#saved-recovery'); if (!panel) return;
  const recovery = connections.recovery; panel.hidden = !recovery;
  if (!recovery) { panel.innerHTML = ''; return; }
  const form = document.querySelector<HTMLFormElement>('#connect-form');
  const busy = connectionCommit || (form && busyConnectionForms.has(form)) ? ' disabled' : '';
  panel.innerHTML = `<h2>Saved connections need attention.</h2><p>${escape(recovery.message)}</p>${recovery.pendingRemember ? '<p>Your Remember choice is pending. This connection is usable now, but is not saved yet.</p>' : ''}${recovery.pendingRemovals ? '<p>Sign-out removed the connection from this session. Its saved removal is pending recovery; verify it after reopening.</p>' : ''}${replaceSavedPending ? `<p role="alert">Replace the unreadable saved data with the connections currently shown? Only remembered connections will be saved. This cannot restore unknown entries from the unreadable data.</p><div class="actions">${button('cancel-replace-saved', 'Cancel', undefined, 'button quiet', busy)}${button('confirm-replace-saved', 'Replace saved data', undefined, 'button primary', busy)}</div>` : recovery.canReplace ? `<div class="actions">${button('retry-saved', 'Retry saved connections', undefined, 'button quiet', busy)}${button('request-replace-saved', 'Replace saved connections', undefined, 'text-button', busy)}</div>` : '<p class="field-note">Storage must be available again before saved connections can be recovered. Reopen Reel when it is permitted.</p>'}`;
}

function renderConnections(): void {
  show(`<div class="connections-page">${header(connections.all.length ? 'Servers' : 'Connect to Jellyfin', '')}<div class="connections-layout"><section class="connection-intro"><span class="connection-brand"><img src="./brand/mark.svg" alt=""/><span>Reel</span></span><h2>Your library.<br>Beautifully played.</h2><p>Movies, series and everything you love, streamed from your own Jellyfin server.</p><span class="protection-note">${icon('shield')}<span>Private by design. No analytics.</span></span></section><div class="connection-form-column"><section class="saved-connections"${connections.all.length ? '' : ' hidden'}><h2>Your servers</h2>${connections.all.length ? connections.all.map(account => `<article><span class="avatar">${escape(account.name.slice(0, 1).toUpperCase())}</span><div><strong>${escape(account.name)}</strong><small>${escape(account.serverName)} · ${escape(account.server)}</small></div>${account.id === connections.activeId ? '<span class="current-label">Current</span>' : button('switch-connection', 'Open', undefined, 'button quiet', `data-id="${escape(account.id)}"`)}${button('remove-connection', 'Sign out', undefined, 'text-button', `data-id="${escape(account.id)}"`)}</article>`).join('') : '<p>Add a Jellyfin connection below.</p>'}</section><section id="saved-recovery" class="storage-recovery" role="status" aria-live="polite" aria-label="Saved connection recovery" hidden></section><form id="connect-form" class="connect-form"><h2>Your server</h2><label>Server address<input name="server" type="url" placeholder="https://jellyfin.example.com" autocomplete="url" required /></label><label>Username<input name="username" autocomplete="username" required /></label><label>Password<input name="password" type="password" autocomplete="current-password" /></label><label class="checkbox"><input type="checkbox" name="remember" ${(desktop ? !desktop.canRemember : !connections.canRemember) ? 'disabled' : ''} /><span>Remember this connection on this device</span></label><p class="field-note">${desktop ? escape(desktop.storageMessage) : 'Your password is never saved. Leave Remember off on shared devices.'}</p><p class="field-note">Use HTTPS outside your home network. HTTP connections are unencrypted.</p><p id="connection-status" class="field-note" role="status" hidden>Finishing this connection change…</p><p id="connection-error" class="form-error" role="alert"></p><button class="button primary" type="submit">${icon('arrow')}<span>Sign in</span></button></form></div></div></div>`, layout !== 'tv');
  if (layout === 'tv') {
    document.body.classList.add('tv-connecting');
    content.querySelector('.page-header h1')!.textContent = 'Connect to Jellyfin';
    content.querySelector('.connection-intro h2')!.innerHTML = 'Your library.<br>The big screen.';
    content.querySelector('.connection-intro > p')!.textContent = 'Movies and series from your Jellyfin server.';
    content.querySelector('.connect-form > .field-note')!.textContent = 'Use HTTPS outside your home network.';
    const saved = content.querySelector<HTMLElement>('.saved-connections');
    if (saved && !saved.querySelector('article')) saved.hidden = true;
    stopTVConnectionForm = installTVConnectionForm(content.querySelector<HTMLFormElement>('#connect-form')!);
    // Focus never starts on Sign out, where a reflex OK would end the session: it starts on another server or the address.
    restoreFocus(content, '.saved-connections [data-action="switch-connection"]:not([disabled]), [data-tv-field="server"]:not([disabled])');
  }
  renderSavedRecovery();
}

function renderSettings(): void {
  show(`${header('Settings', '')}<div class="settings-grid"><section class="settings-panel"><h2>Playback</h2><label>Streaming quality<select id="quality"><option value="120000000"${selected(quality, 120000000)}>Original / auto</option><option value="20000000"${selected(quality, 20000000)}>High · 20 Mbps</option><option value="8000000"${selected(quality, 8000000)}>Balanced · 8 Mbps</option><option value="2000000"${selected(quality, 2000000)}>Data saver · 2 Mbps</option></select></label><label class="checkbox switch"><span>Private viewing</span><input id="history" type="checkbox" role="switch" ${history ? '' : 'checked'} ${currentAPI?.protected ? 'disabled' : ''} /></label><p>${currentAPI?.protected ? 'This preview keeps watch history and library changes off for this server.' : 'Watch progress stays on this device.'}</p></section><section class="settings-panel"><h2>Privacy</h2><p>${icon('shield')}Reel has no analytics or tracking.</p><p>Artwork is cached in memory and cleared when you switch accounts.</p><p>${desktop ? escape(desktop.storageMessage) : connections.recovery ? escape(connections.recovery.message) : `Your password is never saved. Remembered connections stay ${layout === 'tv' ? 'on this TV' : 'in this browser'} until you sign out.`}</p>${!desktop && connections.recovery?.reason === 'unavailable' ? '<p>Quality and Private viewing last for this session only while browser storage is unavailable.</p>' : ''}${button('connections', 'Manage servers', 'connection', 'button quiet')}</section><section class="settings-panel"><h2>About Reel</h2>${layout === 'tv' ? '<p>Use the arrows on your remote to move, OK to select, and Back to return.</p>' : '<p class="keyboard-help">Press / to search. In the player, Space plays or pauses, F switches full screen, the arrow keys seek, and Esc goes back.</p>'}<p>${desktop ? 'Reel for desktop' : config.platform === 'tizen' ? 'Reel for Samsung TV' : config.platform === 'webos' ? 'Reel for LG TV' : 'Reel for the web'}</p><p class="field-note">Offline downloads, recording schedules, media requests, casting and group viewing are not available in this version yet.</p></section></div>`);
}

async function liveTV(generation: number, signal: AbortSignal): Promise<void> {
  const [channels, recordings] = await Promise.all([
    api().page('LiveTv/Channels', { enableUserData: true, limit: 100 }, signal),
    api().page('LiveTv/Recordings', { limit: 30 }, signal).catch(() => ({ Items: [] } as ItemPage))
  ]);
  if (isClosing() || signal.aborted || generation !== routeGeneration) return;
  remember([...channels.Items, ...recordings.Items]);
  show(`${header('Live TV', '')}${channels.Items.length ? `<section class="shelf live-channels"><header><h2>Channels</h2></header><div class="channel-grid">${channels.Items.map(channel => `<button data-action="play" data-id="${escape(channel.Id)}" class="channel-card">${artworkHTML(channel)}<strong>${escape(channel.Name)}</strong>${icon('play')}</button>`).join('')}</div></section>` : empty('No channels here yet.', 'Configure a tuner on Jellyfin to watch live TV.')} ${shelf('Recordings', '', recordings.Items)}`);
}

async function devices(generation: number, signal: AbortSignal): Promise<void> {
  const sessions = await api().request<Array<{ Id: string; DeviceName?: string; Client?: string; UserName?: string; NowPlayingItem?: MediaItem; SupportsRemoteControl?: boolean }>>('Sessions', { signal });
  if (isClosing() || signal.aborted || generation !== routeGeneration) return;
  show(`${header('Devices', '')}<div class="settings-grid">${sessions.map(session => `<section class="settings-panel"><span class="device-symbol">${icon('device')}</span><h2>${escape(session.DeviceName ?? session.Client ?? 'Jellyfin device')}</h2><p>${escape(session.Client ?? '')} · ${escape(session.UserName ?? '')}</p><p>${session.NowPlayingItem ? `Playing ${escape(session.NowPlayingItem.Name)}` : 'Ready to watch.'}</p><p class="field-note">Controlling other screens and SyncPlay are not available in Reel yet.</p></section>`).join('') || empty('No other screens found.', 'Open Jellyfin on another device to see it here.')}</div>`);
}

let lastActiveId = connections.active?.id, lastActiveToken = connections.active?.token;
connections.onChange = () => { if (connectionCommit) connectionChangePending = true; else applyConnectionChange(); };
function applyConnectionChange(): void {
  void track(desktopBrowse?.activate() ?? Promise.resolve());
  const activeChanged = lastActiveId !== connections.active?.id || lastActiveToken !== connections.active?.token;
  lastActiveId = connections.active?.id; lastActiveToken = connections.active?.token;
  if (isClosing() || desktop?.requiresReopen) return;
  if (!activeChanged) { updateAPI(); if (route.name === 'Connections') renderConnections(); else rail(); return; }
  playingId++; closePlayerExtras(); player.close(); playing = false; playerReturnRoute = undefined; presentation.close(); showFormat(false); void exitPlayerFullscreen(playerElement).catch(() => undefined);
  player.reports.discard(); photoElement.hidden = true; document.querySelector('#photo-full')!.removeAttribute('src');
  content.removeAttribute('aria-hidden'); document.querySelector('#rail')!.removeAttribute('aria-hidden');
  browser.close(); browser.clearHistory(); artwork.clear(); items.clear(); detail = undefined; backStack.length = 0; updateAPI();
  void navigate({ name: connections.active ? 'Home' : 'Connections' }, false);
}

/** Closes the open Details menu (Watched or Audio and subtitles). Returns false when none was open. */
function closeDetailMenus(focusButton = true): boolean {
  const menu = content.querySelector<HTMLDetailsElement>('details.detail-menu[open]');
  if (!menu) return false;
  menu.open = false;
  if (focusButton) menu.querySelector<HTMLElement>('summary')?.focus({ preventScroll: true });
  return true;
}
// TV: open Filters is a sheet over the titles and the active filters line, so the remote cannot land on a title
// or on Clear filters hidden behind it. The filter count stays a live status.
function syncFilterSheet(): void {
  const open = document.documentElement.dataset.layout === 'tv' && !!content.querySelector<HTMLDetailsElement>('#browse-filter-panel')?.open;
  for (const node of content.querySelectorAll<HTMLElement>('.browse-results,.browse-pagination,.browse-empty,.browse-filter-summary [data-action="browse-clear-filters"]')) node.inert = open;
}
document.addEventListener('toggle', event => {
  if (event.target instanceof HTMLDetailsElement && event.target.id === 'browse-filter-panel') syncFilterSheet();
}, true);
// A pointer press outside an open Details menu closes it, as any menu does. On a phone the menu is a sheet
// over a dimmed page, and the dimming is drawn by the menu itself, so a press counts as inside only on the
// menu's button or its panel.
document.addEventListener('pointerdown', event => {
  const menu = content.querySelector('details.detail-menu[open]'), target = event.target as Node;
  if (menu && !menu.querySelector(':scope > summary')?.contains(target) && !menu.querySelector(':scope > .detail-menu-panel')?.contains(target)) closeDetailMenus(false);
}, true);

async function back(): Promise<void> {
  if (mobileMoreOpen) { showMobileMore(false); return; }
  if (watchedActions.plan) { if (!watchedActions.busy) await finishWatchedDialog(); return; }
  const resetDialog = document.querySelector('#browse-reset-layer'); if (resetDialog) { closeBrowseReset(); return; }
  if (!playing && closeDetailMenus()) return;
  const filterSheet = layout === 'tv' && !playing ? content.querySelector<HTMLDetailsElement>('#browse-filter-panel[open]') : null;
  if (filterSheet) { filterSheet.open = false; filterSheet.querySelector<HTMLElement>('summary')?.focus({ preventScroll: true }); return; }
  if (playing && !formatPanel.hidden) { showFormat(false); return; }
  if (isClosing() || connectionCommit || desktop?.requiresReopen) return;
  if (replaceSavedPending) { replaceSavedPending = false; renderSavedRecovery(); document.querySelector<HTMLElement>('[data-action="request-replace-saved"]')?.focus(); return; }
  if (document.fullscreenElement) { await document.exitFullscreen(); return; }
  if (!photoElement.hidden) { photoElement.hidden = true; return; }
  if (playing) { await closePlayer(); return; }
  // TV: at a section's top level, Back moves focus to its tab, then from a tab to Home, then exits.
  const tab = layout === 'tv' && connections.active && !backStack.length ? currentTab() : null;
  if (tab) {
    const active = document.activeElement;
    if (active instanceof HTMLElement && content.contains(active)) { tab.focus({ preventScroll: true }); return; }
    if (active?.closest('#rail') && route.name !== 'Home') { await navigate({ name: 'Home' }, false); currentTab()?.focus({ preventScroll: true }); return; }
    if (active?.closest('#rail')) { requestPlatformBack(config.platform, window); return; }
  }
  if (backStack.length) { await navigate(backStack.pop()!, false); return; }
  if (route.name !== 'Home' && connections.active) await navigate({ name: 'Home' }, false);
  else requestPlatformBack(config.platform, window);
}
installNavigation(() => { void back(); }, () => mobileMoreOpen ? document.querySelector<HTMLElement>('#mobile-more-menu')! : document.querySelector<HTMLElement>('#browse-watched-dialog') ?? document.querySelector<HTMLElement>('#browse-reset-dialog') ?? document.querySelector<HTMLElement>('#tv-entry-editor') ?? (!photoElement.hidden ? photoElement : playing ? !formatPanel.hidden ? formatPanel : playerElement : app), {
  // Down past the bottom of the TV transport opens the info panel, as on tvOS.
  edge(direction, active) {
    if (direction !== 'down' || !playing || !formatPanel.hidden || !active.closest('.player-companion')) return false;
    const episodic = !document.querySelector<HTMLElement>('#player-episodes-tab')!.hidden;
    selectPlayerPanel(episodic ? 'episodes' : 'options', 'audio'); showFormat(true);
    return true;
  }
});

app.addEventListener('click', event => {
  if (mobileMoreOpen && !(event.target as HTMLElement).closest('#mobile-more-menu,.mobile-more-toggle')) { showMobileMore(false); return; }
  const target = (event.target as HTMLElement).closest<HTMLElement>('[data-action]');
  if (isClosing() || connectionCommit || desktop?.requiresReopen || !target || target.hasAttribute('disabled') || !playerActivationAllowed(target)) return;
  if (watchedActions.plan && !target.closest('#browse-watched-layer')) return;
  if (document.querySelector('#browse-reset-layer') && !target.closest('#browse-reset-layer')) return;
  const action = target.dataset.action, id = target.dataset.id;
  // TV tabs switch sections rather than adding history, so Back walks up to the tab bar and out.
  const tabSwitch = layout === 'tv' && !!target.closest('#rail') && (action === 'nav' || action === 'home-category');
  if (tabSwitch) backStack.length = 0;
  // A choice in a Library menu closes it and leaves focus on the menu's button, which outlives the re-render;
  // leaving selection mode returns focus to the menu that started it.
  const browseMenu = target.closest<HTMLDetailsElement>('.browse-page details.detail-menu');
  if (browseMenu) { browseMenu.open = false; browseMenu.querySelector<HTMLElement>('summary')?.focus({ preventScroll: true }); }
  else if (action === 'browse-selection') content.querySelector<HTMLElement>('#browse-menu-toggle')?.focus({ preventScroll: true });
  void track((async () => {
    try {
      if (action === 'browse-dismiss-cleanup') { for (const notice of cleanupNotices) dismissedCleanupNotices.add(notice.id); while (dismissedCleanupNotices.size > 64) dismissedCleanupNotices.delete(dismissedCleanupNotices.values().next().value!); content.querySelector('#browse-cleanup-notice')?.remove(); content.focus({ preventScroll: true }); }
      else if (action === 'nav') await navigate({ name: target.dataset.route! }, !tabSwitch);
      else if (action === 'toggle-more') showMobileMore(!mobileMoreOpen);
      else if (action === 'toggle-rail') toggleRail();
      else if (action === 'overview-more') {
        const overview = content.querySelector<HTMLElement>('#detail-overview'), expanded = !overview?.classList.contains('expanded');
        overview?.classList.toggle('expanded', expanded);
        const label = expanded ? 'Show less' : 'Read more';
        target.setAttribute('aria-expanded', String(expanded)); target.setAttribute('aria-label', label); target.querySelector('span')!.textContent = label;
      }
      else if (action === 'close-more') showMobileMore(false);
      else if (action === 'feature' && id) selectHomeFeature(id);
      else if (action === 'home-category') await navigate({ name: 'Library', filter: target.dataset.category }, !tabSwitch);
      else if (action === 'detail') await navigate({ name: 'Details', item: id! });
      else if (action === 'play' || action === 'start-over') await playItem(id!, action === 'start-over');
      else if (action === 'back') await back();
      else if (action === 'retry') await navigate(route, false);
      else if (action === 'connections') await navigate({ name: 'Connections' });
      else if (action === 'browse-category') await navigate({ ...route, filter: target.dataset.category, intent: undefined, scrollY: 0, focus: undefined, focusId: 'browse-category-' + target.dataset.category }, false);
      else if (action === 'refresh-episodes' && homeEpisodeState) await refreshHomeEpisodes(homeEpisodeState, true);
      else if (action === 'browse-newest-episodes') await navigate({ name: 'Library', filter: 'Episodes', intent: 'newest-episodes' });
      else if (action === 'browse-folder') await navigate({ name: 'Library', parent: id, parentType: detail?.Type });
      else if (action === 'browse-more') await browser.load('append');
      else if (action === 'browse-refresh') await browser.load('refresh');
      else if (action === 'browse-retry') await browser.load(browser.state?.errorKind ?? 'first');
      else if (action === 'browse-options-retry') await browser.retryOptions();
      else if (action === 'browse-view' && (target.dataset.view === 'grid' || target.dataset.view === 'list')) await browser.change({ view: target.dataset.view });
      else if (action === 'browse-clear-filters') { if (route.library) await navigate({ ...route, library: '', clearFilters: true, scrollY: undefined, focus: undefined }, false); else await browser.clearFilters(); }
      else if (action === 'browse-clear-query') { if (searchTimer) clearTimeout(searchTimer); searchDraft++; route = { ...route, query: '' }; await browser.search(''); }
      else if (action === 'browse-preferences-retry') await browser.retryPreferences();
      else if (action === 'browse-preferences-reset') showBrowseReset();
      else if (action === 'browse-reset-cancel') closeBrowseReset();
      else if (action === 'browse-reset-confirm') { const own = resetOwner === browseOwner(); closeBrowseReset(); if (own) await browser.resetPreferences(); }
      else if (action === 'browse-selection') browser.toggleSelection();
      else if (action === 'browse-select-loaded') browser.selectLoaded();
      else if (action === 'browse-select-item') browser.toggleSelection(target.dataset.browseSelect);
      else if (action === 'browse-favorites-toggle') await browser.change({ favoritesOnly: !browser.state?.choices.favoritesOnly });
      else if (action === 'browse-watched') prepareWatched(browser.selectedItems(), target.dataset.value === 'true');
      else if (action === 'watched' && detail) { if (isKnownLeafItem(detail) && itemWatched(detail) !== undefined) await mutateDetail('watched'); else prepareWatched([detail], itemWatched(detail) !== true); }
      else if (action === 'watched-mark' && detail) { closeDetailMenus(); prepareWatched([detail], target.dataset.value === 'true'); }
      else if (action === 'watched-confirm') await watchedActions.confirm();
      else if (action === 'watched-cancel') await finishWatchedDialog();
      else if (action === 'watched-close') await finishWatchedDialog();
      else if (action === 'watched-retry') watchedActions.retry();
      else if (action === 'favorite' && detail) await mutateDetail(action);
      else if (action === 'request-replace-saved') { replaceSavedPending = true; renderSavedRecovery(); document.querySelector<HTMLElement>('[data-action="cancel-replace-saved"]')?.focus(); }
      else if (action === 'cancel-replace-saved') { replaceSavedPending = false; renderSavedRecovery(); document.querySelector<HTMLElement>('[data-action="request-replace-saved"]')?.focus(); }
      else if (action === 'retry-saved' || action === 'confirm-replace-saved') {
        setConnectionBusy(true); let completed = false;
        try { if (action === 'retry-saved') connections.retrySaved(); else { const closed = await player.closeAndDrain(); if (!closed.resourcesComplete) throw new Error('Playback is still closing. Try again in a moment.'); connections.replaceSaved(); replaceSavedPending = false; } completed = true; }
        finally {
          setConnectionBusy(false); renderSavedRecovery();
          const focus = completed ? '[data-tv-field="server"],#connect-form [name="server"]' : action === 'retry-saved' ? '[data-action="retry-saved"]' : '[data-action="cancel-replace-saved"]';
          document.querySelector<HTMLElement>(focus)?.focus();
        }
      }
      else if (action === 'switch-connection') { setConnectionBusy(true); target.setAttribute('disabled', ''); try { const closed = await player.closeAndDrain(); if (!closed.resourcesComplete) throw new Error('Playback is still closing. Try again in a moment.'); if (!isClosing()) await connections.switch(id!); } finally { setConnectionBusy(false); } }
      else if (action === 'remove-connection') { setConnectionBusy(true); target.setAttribute('disabled', ''); try { const account = connections.all.find(value => value.id === id); if (account) { const released = account.id === connections.activeId ? (await player.closeAndDrain()).resourcesComplete : await player.drainAccountResources(account.id); if (!released) throw new Error('Playback is still closing. Try sign-out again in a moment.'); } if (isClosing()) return; await removeConnectionAndRevoke({ account, remove: () => connections.remove(id!), remaining: () => connections.all,
          afterRemove: async removed => { if (!hasBrowseAlias(removed, connections.all)) { try { await browser.preferences.removeAccount({ server: removed.server, userId: removed.userId }); } catch (error) { toast(error instanceof Error ? error.message : 'Signed out. Browse choices could not be removed from this device.'); } } },
          revoke: removed => new JellyfinAPI(removed, removed.server, device, config.previewMode, history).request<void>('Sessions/Logout', { method: 'POST' }).catch(() => toast('Signed out here. The server was unavailable to revoke its session.'))
        }); } finally { setConnectionBusy(false); } }
      else if (action === 'format') { selectPlayerPanel('options'); showFormat(true); }
      else if (action === 'player-episodes') { selectPlayerPanel('episodes'); showFormat(true); }
      else if (action === 'player-panel') selectPlayerPanel(target.dataset.panel === 'episodes' ? 'episodes' : 'options', target.dataset.section);
      else if (action === 'season-tab' && id) { if (id !== selectedSeason) selectSeason(id); }
      else if (action === 'tv-key') typeSearch(target.dataset.key ?? '');
      else if (action === 'tv-episodes') {
        const first = content.querySelector<HTMLElement>('.episode-grid .episode-main') ?? content.querySelector<HTMLElement>('.season-tab[aria-pressed="true"]');
        if (first) { first.focus({ preventScroll: true }); if (layout === 'tv') revealTV(first); else first.closest('.episodes')?.scrollIntoView({ block: 'start' }); }
      }
      else if (action === 'retry-player-episodes') { if (episodeContext) await changePlayerSeason(episodeContext.selectedSeason); else if (currentPlayingItem) await loadPlayerExtras(currentPlayingItem, playingId); }
      else if (action === 'player-episode' && id && episodeContext?.episodes.some(episode => episode.Id === id)) { cancelAutoNext(); if (id === currentPlayingItem?.Id) showFormat(false); else await playItem(id); }
      else if (action === 'play-previous' && previousEpisode) await playItem(previousEpisode.Id, true);
      else if (action === 'skip-intro' && introSegment && Number.isFinite(video.duration) && introSegment.end <= video.duration && video.currentTime >= introSegment.start && video.currentTime < introSegment.end) { player.seek(introSegment.end); updateTransport(); }
      else if (action === 'cancel-autoplay') cancelAutoNext(true);
      else if (action === 'close-format') showFormat(false);
      else if (action === 'close-player') await closePlayer();
      else if (action === 'retry-player') { playerTransitionPending = true; player.retry(); }
      else if (action === 'restore-player-options' && playbackChange) changePlaybackSettings(playbackChange.previous);
      else if (action === 'replay-player' && currentPlayingItem) await playItem(currentPlayingItem.Id, true);
      else if (action === 'play-next' && nextEpisode) await playItem(nextEpisode.Id, true);
      else if (action === 'skip-back') player.skip(-skipSeconds);
      else if (action === 'skip-forward') player.skip(skipSeconds);
      else if (action === 'toggle-play') player.toggle();
      else if (action === 'fullscreen') await togglePlayerFullscreen(playerElement);
      else if (action === 'close-photo') photoElement.hidden = true;
      else if (action === 'photo' && id) { const item = items.get(id)!, revision = connections.revision, generation = routeGeneration; const image = await artwork.get(api(), item, 'poster', 3840); if (isClosing() || revision !== connections.revision || generation !== routeGeneration) return; const full = document.querySelector<HTMLImageElement>('#photo-full')!; full.src = image; full.alt = item.Name; photoElement.hidden = false; restoreFocus(photoElement); }
      else if (action === 'book' && id) await downloadBook(id);
    } catch (error) { if (recoverUncertainStore(error)) return; target.removeAttribute('disabled'); if (!(error instanceof DOMException && error.name === 'AbortError')) toast(error instanceof Error ? error.message : 'This action could not be completed.'); }
  })());
});

app.addEventListener('submit', event => {
  if (isClosing() || desktop?.requiresReopen) { event.preventDefault(); return; }
  const form = event.target as HTMLFormElement;
  event.preventDefault();
  if (form.id === 'search-form') { if (searchTimer) clearTimeout(searchTimer); searchDraft++; const query = String(new FormData(form).get('query') ?? ''); route = { ...route, query }; void track(browser.search(query)); return; }
  if (form.id !== 'connect-form') return;
  const data = new FormData(form), button = form.querySelector<HTMLButtonElement>('button[type="submit"]')!;
  if (button.disabled || connectionCommit) return;
  const revision = connections.revision, generation = routeGeneration, signal = routeController.signal;
  lockConnectionForm(form, true); button.querySelector('span')!.textContent = 'Connecting…';
  document.querySelector('#connection-error')!.textContent = '';
  void track((async () => {
    try {
      const anonymous = new JellyfinAPI(null, String(data.get('server')), device, config.previewMode);
      const authenticated = await anonymous.authenticate(String(data.get('username')), String(data.get('password') ?? ''), data.get('remember') === 'on', signal);
      const account = desktopAccount(authenticated, desktop?.canRemember ?? true);
      const cleanup = () => track(revokeUnusedSession(account, () => connections.all, removed => new JellyfinAPI(removed, removed.server, device, config.previewMode).request<void>('Sessions/Logout', { method: 'POST' }).catch(() => undefined)));
      if (isClosing() || revision !== connections.revision || generation !== routeGeneration || signal.aborted || !form.isConnected) { await cleanup(); return; }
      form.querySelector<HTMLInputElement>('[name="password"]')!.value = '';
      setConnectionBusy(true);
      try { await connections.add(account); } catch (error) { if (!uncertainDesktopError(error)) await cleanup(); throw error; }
      finally { setConnectionBusy(false); }
      if (!isClosing() && route.name === 'Connections') await navigate({ name: 'Home' }, false);
    } catch (error) { if (recoverUncertainStore(error)) return; if (form.isConnected && !signal.aborted) document.querySelector('#connection-error')!.textContent = error instanceof Error ? error.message : 'Sign-in could not be completed.'; }
    finally { lockConnectionForm(form, false); if (form.isConnected) { button.querySelector('span')!.textContent = 'Sign in'; renderSavedRecovery(); } }
  })());
});

app.addEventListener('input', event => {
  if (isClosing() || desktop?.requiresReopen || watchedActions.plan) return;
  const input = event.target as HTMLInputElement;
  if (input.id !== 'search' || !browser.state) return;
  if (searchTimer) clearTimeout(searchTimer);
  const value = input.value, generation = routeGeneration, revision = connections.revision, draft = ++searchDraft;
  // Cancel old work immediately, but keep the focused input mounted while typing.
  browser.cancelPendingQuery(value); route = { ...route, query: value };
  if (!value.trim()) { void track(browser.search(value)); return; }
  searchTimer = setTimeout(() => {
    searchTimer = undefined;
    if (isClosing() || generation !== routeGeneration || revision !== connections.revision || draft !== searchDraft) return;
    route = { ...route, query: value }; void track(browser.search(value));
  }, 300);
});

app.addEventListener('change', event => {
  if (isClosing() || desktop?.requiresReopen) return;
  const field = event.target as HTMLInputElement;
  if (watchedActions.plan) return;
  if (field.id === 'sort') void track(browser.change({ sort: field.value as LibrarySort }));
  if (field.id === 'browse-direction' && (field.value === 'Ascending' || field.value === 'Descending')) void track(browser.change({ direction: field.value }));
  if (field.id === 'browse-genre') void track(browser.change({ genreId: field.value }));
  if (field.id === 'browse-watch' && (field.value === 'Any' || field.value === 'Watched' || field.value === 'Unwatched')) void track(browser.change({ watchStatus: field.value }));
  if (field.id === 'browse-library') void navigate({ ...route, library: field.value, scrollY: 0, focus: undefined, focusId: 'browse-library' }, false);
  if (field.id === 'quality') { quality = Number(field.value); storage.setItem('reel.quality', String(quality)); if (desktop) void track(desktop.savePreferences(quality, history, autoNext)).catch(error => { if (!recoverUncertainStore(error)) toast(error.message); }); }
  // The control reads "Private viewing", so on means progress is not sent; the stored value still means "send".
  if (field.id === 'history') { history = !field.checked; if (!history) player.reports.discard(); storage.setItem('reel.history', String(history)); updateAPI(); if (desktop) void track(desktop.savePreferences(quality, history, autoNext)).catch(error => { if (!recoverUncertainStore(error)) toast(error.message); }); }
  if (['player-quality', 'player-audio', 'player-subtitles', 'player-version'].includes(field.id) && playbackSelection && !field.disabled) {
    const next = field.id === 'player-version' ? selectPlaybackSource(playbackSelection, field.value) : { ...playbackSelection, [field.id === 'player-quality' ? 'bitrate' : field.id === 'player-audio' ? 'audio' : 'subtitle']: field.value === '' ? undefined : Number(field.value) };
    changePlaybackSettings(next);
  }
  if (field.id === 'player-season') void track(changePlayerSeason(field.value));
  if (field.id === 'player-autoplay') { autoNext = field.checked; storage.setItem('reel.autoplay', String(autoNext)); if (!autoNext) cancelAutoNext(true); if (desktop) void track(desktop.savePreferences(quality, history, autoNext)).catch(error => { if (!recoverUncertainStore(error)) toast(error.message); }); }
  if (field.id === 'speed') video.playbackRate = Number(field.value);
  if (field.id === 'player-seek') { scrubbing = false; player.seek(Number(field.value)); updateTransport(); }
  if (field.id === 'chapters') player.seek(Number(field.value));
  if (field.id === 'audio-track') selectedAudio = field.value;
  if (field.id === 'subtitle-track') selectedSubtitle = field.value;
  if (field.id === 'media-source') { selectedMediaSource = field.value; selectedAudio = ''; selectedSubtitle = ''; renderDetail(); }
  if (field.id === 'season') selectSeason(field.value);
});
// The season menu (and the TV season tabs) load that season's episodes into the detail page.
function selectSeason(season: string): void {
  if (!detail || seasonLoading) return;
  const previous = selectedSeason, item = detail, generation = routeGeneration;
  selectedSeason = season; seasonLoading = true; renderDetail();
  void api().page(`Shows/${encodeURIComponent(item.Id)}/Episodes`, { seasonId: season, isMissing: false }, routeController.signal).then(page => {
    if (isClosing() || generation !== routeGeneration || detail?.Id !== item.Id) return;
    episodes = page.Items; remember(episodes); seasonLoading = false; renderDetail();
  }).catch(error => {
    if (isClosing() || generation !== routeGeneration || detail?.Id !== item.Id) return;
    selectedSeason = previous; seasonLoading = false; renderDetail(); toast(error.message);
  });
}

document.addEventListener('keydown', event => {
  if (isClosing() || !playing || !formatPanel.hidden) return;
  // TV: the picture seeks with Left and Right and plays or pauses with OK.
  if (layout === 'tv' && event.target === video && ['playing', 'paused'].includes(playerElement.dataset.state ?? '')) {
    if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') { event.preventDefault(); player.skip(event.key === 'ArrowLeft' ? -skipSeconds : skipSeconds); return; }
    if (event.key === 'Enter') { event.preventDefault(); player.toggle(); return; }
  }
  // Native video controls already handle Space; a second toggle would immediately resume.
  if (event.key === ' ' && event.target === video && video.controls) return;
  if (event.target === video && video.controls && ['ArrowLeft', 'ArrowRight'].includes(event.key)) {
    event.preventDefault(); player.skip(event.key === 'ArrowLeft' ? -skipSeconds : skipSeconds); return;
  }
  const interactive = (event.target as HTMLElement).closest('button,input,select,textarea,a,[contenteditable="true"]');
  if (event.key === 'MediaPlayPause' || event.key === ' ' && !interactive) { event.preventDefault(); player.toggle(); }
  if (event.key === 'MediaRewind') player.skip(-skipSeconds);
  if (event.key === 'MediaFastForward') player.skip(skipSeconds);
});
// Desktop shortcuts: "/" opens Search, F toggles full screen in the player.
document.addEventListener('keydown', event => {
  if (isClosing() || layout === 'tv' || event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;
  if ((event.target as HTMLElement).closest?.('input,textarea,select,[contenteditable="true"]')) return;
  if (playing) {
    if (event.key.toLowerCase() === 'f' && formatPanel.hidden) {
      event.preventDefault();
      void togglePlayerFullscreen(playerElement).catch(error => toast(error instanceof Error ? error.message : 'Full screen is unavailable.'));
    }
    return;
  }
  if (event.key !== '/' || !connections.active || mobileMoreOpen || watchedActions.plan || document.querySelector('#browse-reset-layer') || !photoElement.hidden) return;
  event.preventDefault();
  if (route.name === 'Search') content.querySelector<HTMLInputElement>('#search')?.focus();
  else void track(navigate({ name: 'Search' }));
});
lifecycle?.setDrain(async () => {
  closePlayerExtras();
  routeGeneration++; playingId++; routeController.abort(); browser.close(); watchedActions.cancel();
  if (searchTimer) { clearTimeout(searchTimer); searchTimer = undefined; }
  homeEpisodeState = undefined; stopEpisodeArt?.(); stopEpisodeArt = undefined;
  stopTVConnectionForm?.(); stopTVConnectionForm = undefined;
  connections.close(); desktop?.close(); artwork.clear();
  await Promise.allSettled([desktopBrowse?.close() ?? Promise.resolve(), player.closeAndDrain(), connections.drain(), desktop?.drain() ?? Promise.resolve(), ...pendingWork]);
  presentation.dispose();
  player.reports.dispose();
});
installPageCacheRecovery(window, {
  suspend(persisted) {
    routeGeneration++; playingId++; routeController.abort();
    if (searchTimer) { clearTimeout(searchTimer); searchTimer = undefined; }
    homeEpisodeState = undefined; stopEpisodeArt?.(); stopEpisodeArt = undefined; browser.close(); watchedActions.cancel();
    closePlayerExtras(); player.close(); playing = false; presentation.close(); showFormat(false); void exitPlayerFullscreen(playerElement).catch(() => undefined);
    if (!persisted) { presentation.dispose(); void desktopBrowse?.close().catch(() => undefined); }
  },
  restore() {
    if (isClosing()) return;
    updateAPI(); void track(desktopBrowse?.activate() ?? Promise.resolve());
    const returning = playerReturnRoute ?? route; playerReturnRoute = undefined;
    const navigation = navigate(returning, false, true), owner = browseOwner();
    void track(restoreAfterNavigation(navigation, owner, () => !isClosing() && route.name === returning.name && route.item === returning.item ? browseOwner() : undefined, () => restorePlayerReturnFocus(returning)));
  }
});
void track(desktopBrowse?.activate() ?? Promise.resolve());
void navigate(route, false);
setupPWA({ platform: config.platform, production: import.meta.env.PROD, canUpdate: () => !playing && !playerTransitionPending && !connectionCommit && !connectionChangePending && !pendingMutations.size && !watchedActions.busy && !watchedActions.plan && !pendingWork.size });

}
void boot().catch(error => { const app = document.querySelector('#app'); if (app) { app.innerHTML = '<main class="connection-intro"><h1>Reel could not open.</h1><p></p>' + (uncertainDesktopError(error) ? '' : '<button class="button primary" id="boot-retry">Try again</button>') + '</main>'; app.querySelector('p')!.textContent = uncertainDesktopError(error) ? desktopError('uncertain').message : 'Reopen the app to try again.'; app.querySelector('#boot-retry')?.addEventListener('click', () => location.reload()); } });

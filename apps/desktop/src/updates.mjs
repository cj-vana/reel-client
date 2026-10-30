// Keeps the desktop app current from this project's GitHub releases. A macOS build signed with a Developer ID
// installs updates itself through Squirrel.Mac, which reads a small feed attached to each release. Other builds
// are not code signed, so they only report that a new version exists and open its release page.
export const REPOSITORY = 'cj-vana/reel-client';
export const CHECK_EVERY_MS = 12 * 3_600_000;
const FIRST_CHECK_MS = 30_000;
const TAG = /^v(\d+)\.(\d+)\.(\d+)$/;

/** Compares MAJOR.MINOR.PATCH versions, with or without a leading v. A pre-release suffix sorts first. */
export function compareVersions(a, b) {
  const parse = value => {
    const match = /^v?(\d+)\.(\d+)\.(\d+)(-.+)?$/.exec(String(value));
    return match ? [Number(match[1]), Number(match[2]), Number(match[3]), match[4] ? 0 : 1] : undefined;
  };
  const left = parse(a), right = parse(b);
  if (!left || !right) return NaN;
  for (let index = 0; index < 4; index++) if (left[index] !== right[index]) return left[index] < right[index] ? -1 : 1;
  return 0;
}

/** The feed Squirrel.Mac reads; GitHub redirects latest/download to the newest published release's asset. */
export const feedURL = arch => `https://github.com/${REPOSITORY}/releases/latest/download/reel-desktop-macos-${arch}.json`;
export const releasePage = tag => {
  if (!TAG.test(tag)) throw new Error('Unexpected release tag');
  return `https://github.com/${REPOSITORY}/releases/tag/${tag}`;
};

export class UpdateService {
  #version; #arch; #install; #fetch; #updater; #open; #enabled; #setTimer; #clearTimer; #now;
  #timer; #listeners = new Set(); #tag = null; #wired = false;
  state = { status: 'idle', version: null, mode: 'download', checkedAt: null };

  /**
   * install: true for a Developer ID-signed macOS build, whose `updater` is Electron's autoUpdater.
   * enabled: reads the saved "check for updates" choice each time a check is due.
   */
  constructor({ version, arch, install, fetch, updater, openExternal, enabled, setTimer = setTimeout, clearTimer = clearTimeout, now = Date.now }) {
    this.#version = version; this.#arch = arch; this.#install = install === true && !!updater; this.#fetch = fetch; this.#updater = updater;
    this.#open = openExternal; this.#enabled = enabled; this.#setTimer = setTimer; this.#clearTimer = clearTimer; this.#now = now;
    this.state = { ...this.state, mode: this.#install ? 'install' : 'download' };
  }

  subscribe(listener) { this.#listeners.add(listener); return () => this.#listeners.delete(listener); }
  #set(change) {
    this.state = { ...this.state, ...change };
    for (const listener of this.#listeners) { try { listener(this.state); } catch { /* A closed window cannot stop updates. */ } }
  }

  /** Starts the schedule: a first check shortly after launch, then every twelve hours. */
  start() { this.#schedule(FIRST_CHECK_MS); }
  stop() { this.#clearTimer(this.#timer); this.#timer = undefined; }
  #schedule(delay) {
    this.stop();
    this.#timer = this.#setTimer(() => { void this.check().finally(() => this.#schedule(CHECK_EVERY_MS)); }, delay);
  }

  async check({ manual = false } = {}) {
    if (!manual && !this.#enabled()) { this.#set({ status: 'off' }); return this.state; }
    if (['checking', 'downloading', 'ready'].includes(this.state.status)) return this.state;
    this.#set({ status: 'checking' });
    if (this.#install) {
      this.#wire();
      try { this.#updater.checkForUpdates(); } catch { await this.#checkRelease(); }
      return this.state;
    }
    await this.#checkRelease();
    return this.state;
  }

  #wire() {
    if (this.#wired) return;
    this.#wired = true;
    // Listeners first: setting the feed can report an error straight away, and an unheard error event throws.
    this.#updater.on('update-available', () => this.#set({ status: 'downloading' }));
    this.#updater.on('update-not-available', () => this.#set({ status: 'current', checkedAt: this.#now() }));
    this.#updater.on('update-downloaded', (_event, _notes, name) => {
      this.#set({ status: 'ready', version: compareVersions(name, '0.0.0') > 0 ? String(name).replace(/^v/, '') : this.state.version, checkedAt: this.#now() });
    });
    // When Squirrel cannot update (for example when Reel runs from the Downloads folder), the release check still
    // tells the person a new version exists.
    this.#updater.on('error', () => { if (this.state.status !== 'ready') void this.#checkRelease(); });
    this.#updater.setFeedURL({ url: feedURL(this.#arch), serverType: 'json' });
  }

  async #checkRelease() {
    try {
      const response = await this.#fetch(`https://api.github.com/repos/${REPOSITORY}/releases/latest`, { headers: { Accept: 'application/vnd.github+json' } });
      // No published release yet.
      if (response.status === 404) { this.#tag = null; this.#set({ status: 'current', version: null, checkedAt: this.#now() }); return; }
      if (!response.ok) throw new Error('Release check failed');
      const release = await response.json(), tag = release?.tag_name;
      if (typeof tag !== 'string' || !TAG.test(tag) || release.draft || release.prerelease) throw new Error('Unexpected release');
      const newer = compareVersions(tag, this.#version) > 0;
      this.#tag = newer ? tag : null;
      this.#set({ status: newer ? 'available' : 'current', version: newer ? tag.slice(1) : null, mode: newer && this.#install ? 'download' : this.state.mode, checkedAt: this.#now() });
    } catch { this.#set({ status: 'error', checkedAt: this.#now() }); }
  }

  /** Restarts into a downloaded update. */
  install() {
    if (this.state.status !== 'ready') return false;
    this.#updater.quitAndInstall();
    return true;
  }

  /** Opens the new release's page in the browser. */
  async download() {
    if (this.state.status !== 'available' || !this.#tag) return false;
    await this.#open(releasePage(this.#tag));
    return true;
  }
}

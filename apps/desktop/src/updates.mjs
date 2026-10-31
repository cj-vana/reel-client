// Keeps the desktop app current from this project's GitHub releases, without a code-signing certificate. Each
// release attaches a manifest signed with the project's update key. Reel downloads the ZIP it names for this
// computer, checks it, unpacks it beside the installed copy, and swaps it in after it quits. Where Reel cannot
// replace itself (no update key, a copy outside Applications on a Mac, no write access), it says that a new
// version exists and opens the release page instead.
import { mkdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { compareVersions, downloadFile, installLocation, readManifest, readSmall, RELEASES, releaseURLs, REPOSITORY, UpdateError } from './update-package.mjs';
import { executableInside, helperScript, removeLeftovers, RESULT_FILE, stageRelease, startHelper, takeResult } from './update-install.mjs';

export { compareVersions, REPOSITORY };
export const CHECK_EVERY_MS = 12 * 3_600_000;
const FIRST_CHECK_MS = 30_000;
const TAG = /^v(\d+)\.(\d+)\.(\d+)$/;

export const releasePage = tag => {
  if (!TAG.test(tag)) throw new Error('Unexpected release tag');
  return `https://github.com/${REPOSITORY}/releases/tag/${tag}`;
};

export class UpdateService {
  // #reason: why this copy opens the release page instead of installing (null when it installs, or has no key).
  #o; #timer; #listeners = new Set(); #tag = null; #location = null; #reason = null; #ready = null; #relaunch = false; #handedOver = false;
  /**
   * status: idle, off, checking, current, available, downloading, ready or error. mode: install when Reel replaces
   * itself, download when it opens the release page. problem: why not, or what failed.
   */
  state = { status: 'idle', version: null, mode: 'download', checkedAt: null, progress: null, problem: null };

  /**
   * version, platform, arch, execPath, name (the packaged app name) and userData describe this copy of Reel.
   * publicKey: the update key, or null. releases: where releases live (a loopback server for QA builds).
   * fetch, openExternal, enabled() (the saved choice, read at each scheduled check), inApplications (macOS),
   * relaunchArgs and relaunchEnv (QA builds only) and quit(), which closes Reel through its usual handshake.
   * Tests may replace setTimer, clearTimer, now, stage, launch and locate.
   */
  constructor(options) {
    this.#o = { releases: RELEASES, relaunchArgs: [], relaunchEnv: {}, setTimer: setTimeout, clearTimer: clearTimeout, now: Date.now, stage: stageRelease, launch: undefined, locate: installLocation, ...options };
  }

  subscribe(listener) { this.#listeners.add(listener); return () => this.#listeners.delete(listener); }
  #set(change) {
    this.state = { ...this.state, ...change };
    for (const listener of this.#listeners) { try { listener(this.state); } catch { /* A closed window cannot stop updates. */ } }
  }

  /** Finds where Reel is installed, reports how the last update went, and schedules the first check. */
  async start() {
    const o = this.#o;
    this.#location = await o.locate({ platform: o.platform, arch: o.arch, execPath: o.execPath, name: o.name, inApplications: o.inApplications });
    let installs = !!o.publicKey && this.#location.ok;
    this.#reason = installs || !o.publicKey ? null : this.#location.reason;
    if (this.#location.ok) await removeLeftovers(this.#location.parent);
    // After a swap that failed and was rolled back, this run offers the release page instead of trying again.
    const last = await takeResult(o.userData);
    if (last && !last.ok) { installs = false; this.#reason = 'install'; }
    this.#set({ mode: installs ? 'install' : 'download', problem: this.#reason });
    this.#schedule(FIRST_CHECK_MS);
  }
  stop() { this.#o.clearTimer(this.#timer); this.#timer = undefined; }
  #schedule(delay) {
    this.stop();
    this.#timer = this.#o.setTimer(() => { void this.check().finally(() => this.#schedule(CHECK_EVERY_MS)); }, delay);
  }

  async check({ manual = false } = {}) {
    if (!manual && !this.#o.enabled()) { this.#set({ status: 'off' }); return this.state; }
    if (['checking', 'downloading', 'ready'].includes(this.state.status)) return this.state;
    this.#set({ status: 'checking', progress: null, problem: this.#reason });
    if (this.state.mode === 'install') await this.#checkSigned();
    else await this.#checkRelease();
    return this.state;
  }

  async #checkSigned() {
    const o = this.#o, urls = releaseURLs(o.releases), folder = join(o.userData, 'updates');
    try {
      const [bytes, signature] = await Promise.all([readSmall(o.fetch, urls.manifest), readSmall(o.fetch, urls.signature)]);
      // The newest release carries no manifest (it was published without the update key): offer its page.
      if (!bytes || !signature) { await this.#checkRelease(); return; }
      const release = readManifest(bytes, signature.toString('utf8'), o.publicKey, this.#location.target);
      if (!(compareVersions(release.version, o.version) > 0)) { this.#set({ status: 'current', version: null, checkedAt: o.now() }); return; }
      this.#tag = release.tag;
      this.#set({ status: 'downloading', version: release.version, progress: 0 });
      await rm(folder, { recursive: true, force: true }); await mkdir(folder, { recursive: true, mode: 0o700 });
      const zip = join(folder, release.file.name);
      let shown = 0;
      await downloadFile(o.fetch, urls.asset(release.tag, release.file.name), zip, release.file, {
        onProgress: value => { const percent = Math.floor(value * 100); if (percent !== shown) { shown = percent; this.#set({ progress: value }); } }
      });
      const staged = await o.stage({ platform: o.platform, zip, location: this.#location, version: release.version });
      await rm(folder, { recursive: true, force: true });
      this.#ready = { ...staged, version: release.version };
      this.#set({ status: 'ready', progress: null, checkedAt: o.now() });
    } catch (error) {
      await rm(folder, { recursive: true, force: true }).catch(() => undefined);
      this.#set({ status: 'error', progress: null, problem: error instanceof UpdateError ? error.code : 'download', checkedAt: o.now() });
    }
  }

  async #checkRelease() {
    const o = this.#o;
    // QA builds check only their loopback server, which has no releases API.
    if (o.releases !== RELEASES) { this.#set({ status: 'current', version: null, checkedAt: o.now() }); return; }
    try {
      const response = await o.fetch(`https://api.github.com/repos/${REPOSITORY}/releases/latest`, { headers: { Accept: 'application/vnd.github+json' } });
      // No published release yet.
      if (response.status === 404) { this.#tag = null; this.#set({ status: 'current', version: null, checkedAt: o.now() }); return; }
      if (!response.ok) throw new Error('Release check failed');
      const release = await response.json(), tag = release?.tag_name;
      if (typeof tag !== 'string' || !TAG.test(tag) || release.draft || release.prerelease) throw new Error('Unexpected release');
      const newer = compareVersions(tag, o.version) > 0;
      this.#tag = newer ? tag : null;
      this.#set({ status: newer ? 'available' : 'current', version: newer ? tag.slice(1) : null, checkedAt: o.now() });
    } catch { this.#set({ status: 'error', checkedAt: o.now() }); }
  }

  /** Restarts into a downloaded update: Reel quits, the helper swaps the copies and starts Reel again. */
  install() {
    if (this.state.status !== 'ready' || !this.#ready) return false;
    this.#relaunch = true;
    this.#o.quit();
    return true;
  }

  /** Called as Reel quits. A downloaded update is put in place then, and Reel starts again only after install(). */
  finishOnQuit() {
    if (!this.#ready || this.#handedOver) return false;
    this.#handedOver = true;
    const o = this.#o, ready = this.#ready, location = this.#location;
    const script = helperScript({
      platform: o.platform, pid: process.pid, folder: location.folder, staging: ready.staging, staged: ready.staged, version: ready.version,
      resultFile: join(o.userData, RESULT_FILE), relaunch: this.#relaunch, executable: executableInside(o.execPath, location.folder), args: o.relaunchArgs, env: o.relaunchEnv
    });
    startHelper({ platform: o.platform, staging: ready.staging, script, ...(o.launch ? { launch: o.launch } : {}) });
    return true;
  }

  /** Opens the new release's page in the browser. */
  async download() {
    if (!['available', 'error'].includes(this.state.status) || !this.#tag) return false;
    await this.#o.openExternal(releasePage(this.#tag));
    return true;
  }
}


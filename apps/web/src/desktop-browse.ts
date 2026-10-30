import { normalizeServer } from './api.ts';
import { LibraryPreferenceError, LibraryPreferences } from './library-preferences.ts';
import { type LibraryChoices, type LibraryScope } from './library-query.ts';
import type { BrowseAccount, BrowsePreferenceSnapshot, BrowsePreferenceStore } from './library-browser.ts';
import type { BrowseCleanupNotice, BrowseCode, BrowseDocument, BrowseOpenResult, ReelBrowsePreferences } from './browse-bridge.ts';

declare global { interface Window { ReelBrowsePreferences?: ReelBrowsePreferences } }
export interface BrowseActivation { account: BrowseAccount; owner: string }
interface Admission { owner: string; generation: number }
interface Pending { scope: LibraryScope; patch: Partial<LibraryChoices>; versions: Partial<Record<keyof LibraryChoices, number>>; owners: Partial<Record<keyof LibraryChoices, Admission>> }
interface AccountState { account: BrowseAccount; document?: BrowseDocument; pending: Map<string, Pending>; retention?: 'device' | 'session'; error?: LibraryPreferenceError; canReset: boolean; uncertain?: boolean }
interface Lease { owner: string; generation: number; id?: string; revision?: string; state: AccountState }
const key = (account: BrowseAccount) => JSON.stringify([normalizeServer(account.server), account.userId]);
const scopeKey = (scope: LibraryScope) => JSON.stringify([scope.kind, scope.libraryId, scope.category, scope.parentId, scope.parentType]);
const clone = <T>(value: T): T => JSON.parse(JSON.stringify(value)) as T;
const revision = (value: unknown): value is string => typeof value === 'string' && (value === 'absent' || /^sha256:[a-f0-9]{64}$/.test(value));
const codes: Record<BrowseCode, string> = {
  invalid: 'These browse choices could not be saved safely.', stale: 'The active connection changed. Retry these browse choices in its current view.',
  closing: 'Reel is closing. Reopen it to save browse choices.', conflict: 'Saved browse choices changed. Retry to merge only the choices you edited.',
  unavailable: 'The desktop browse store is unavailable. Your choices work for this visit.', io: 'Browse choices could not be saved. Existing data was left in place; retry when storage is available.',
  preserved: 'Existing browse data could not be safely identified. It has been left untouched.', limit: 'The browse storage limit was reached. Existing choices have been kept.',
  uncertain: 'Reel could not confirm that browse choices were saved. Quit and reopen Reel to reconcile storage before trying again.',
  corrupt: 'This connection’s browse choices could not be read. Retry or confirm Reset saved choices.', unsupported: 'This connection’s browse choices use an unsupported version. Retry or confirm Reset saved choices.'
};
class DesktopBrowseError extends LibraryPreferenceError { readonly code: BrowseCode; constructor(code: BrowseCode) { super(codes[code], false, !['corrupt', 'unsupported'].includes(code)); this.code = code; } }
function failure(code: BrowseCode): DesktopBrowseError { return new DesktopBrowseError(code); }
/** Root-reviewed schema is reused locally to build candidate documents, never as an acknowledgement of disk I/O. */
function engine(account: BrowseAccount, document?: BrowseDocument) {
  let raw = document ? JSON.stringify(document) : null;
  const store = new LibraryPreferences({ getItem: () => raw, setItem: (_key, value) => { raw = value; }, removeItem: () => { raw = null; } });
  return { store, document: () => raw ? JSON.parse(raw) as BrowseDocument : { schema: 1 as const, account: clone(account), entries: [] } };
}

/** Async commit semantics for the dedicated noncredential bridge. No Chromium/credential-store fallback. */
export class DesktopBrowsePreferences implements BrowsePreferenceStore {
  private readonly bridge?: ReelBrowsePreferences;
  private readonly timeoutMs: number;
  private readonly current: () => BrowseActivation | undefined;
  private generation = 0;
  private editVersion = 0;
  private closed = false;
  private closingWork?: Promise<void>;
  private lease?: Lease;
  private activation?: Promise<void>;
  private queue: Promise<unknown> = Promise.resolve();
  private readonly accounts = new Map<string, AccountState>();
  private readonly notices = new Map<string, BrowseCleanupNotice>();
  private noticeHandler?: (notices: readonly BrowseCleanupNotice[]) => void;
  private disposeNotices?: () => void;
  constructor(value: unknown, current: () => BrowseActivation | undefined, timeoutMs = 8000) {
    this.current = current; this.timeoutMs = timeoutMs;
    const methods = ['open', 'commit', 'reset', 'revoke', 'onCleanupNotice'];
    if (value && typeof value === 'object' && methods.every(method => typeof (value as Record<string, unknown>)[method] === 'function')) this.bridge = value as ReelBrowsePreferences;
    if (this.bridge) this.disposeNotices = this.bridge.onCleanupNotice(notice => this.acceptNotices([notice]));
  }
  private async bounded<T>(work: Promise<T>): Promise<T> { let timer: ReturnType<typeof setTimeout>; try { return await Promise.race([work, new Promise<T>((_, reject) => { timer = setTimeout(() => reject(failure('unavailable')), this.timeoutMs); })]); } finally { clearTimeout(timer!); } }
  setNoticeHandler(handler: (notices: readonly BrowseCleanupNotice[]) => void): void { this.noticeHandler = handler; this.deliverNotices(); }
  private deliverNotices(): void { if (!this.closed) this.noticeHandler?.([...this.notices.values()].map(clone)); }
  private acceptNotices(values: readonly BrowseCleanupNotice[]): void {
    if (this.closed || !Array.isArray(values)) return;
    for (const notice of values.slice(0, 16)) {
      if (!notice || Object.keys(notice).sort().join(',') !== 'accountId,code,count,id' || typeof notice.id !== 'string' || !/^[a-zA-Z0-9-]{1,128}$/.test(notice.id)
        || typeof notice.accountId !== 'string' || !/^[a-zA-Z0-9:_-]{1,128}$/.test(notice.accountId) || !Number.isSafeInteger(notice.count) || notice.count < 1 || notice.count > 32 || !['preserved', 'io', 'uncertain'].includes(notice.code)) continue;
      this.notices.set(notice.id, clone(notice)); while (this.notices.size > 16) this.notices.delete(this.notices.keys().next().value!);
    }
    this.deliverNotices();
  }
  private state(account: BrowseAccount): AccountState {
    const identity = { server: normalizeServer(account.server), userId: account.userId }, id = key(identity);
    let state = this.accounts.get(id);
    if (!state) {
      if (this.accounts.size >= 32) {
        const disposable = [...this.accounts].find(([, value]) => !value.pending.size && !value.uncertain && value !== this.lease?.state);
        if (!disposable) throw failure('limit'); this.accounts.delete(disposable[0]);
      }
      state = { account: identity, pending: new Map(), canReset: false }; this.accounts.set(id, state);
    } return state;
  }
  private owns(admission: Admission, lease?: Lease): boolean { return !this.closed && this.current()?.owner === admission.owner && this.generation === admission.generation && (!lease || lease === this.lease); }
  private admit(account: BrowseAccount): Admission {
    const current = this.current(); if (!current || !this.stillCurrent(current.owner, account)) throw failure(this.closed ? 'closing' : 'stale');
    if (this.generation === 0) void this.activate(current);
    return { owner: current.owner, generation: this.generation };
  }
  private sameAdmission(left: Admission | undefined, right: Admission): boolean { return left?.owner === right.owner && left?.generation === right.generation; }
  private stillCurrent(owner: string, account: BrowseAccount): boolean { const current = this.current(); return !this.closed && current?.owner === owner && key(current.account) === key(account); }
  /** Called immediately on every account/token revision, including a Home destination. */
  activate(value = this.current()): Promise<void> {
    const generation = ++this.generation; this.lease = undefined;
    const work = (async () => {
      if (!this.bridge) { if (value) { const state = this.state(value.account); state.error = failure('unavailable'); this.lease = { owner: value.owner, generation, state }; } return; }
      if (!value) { const result = await this.bounded(this.bridge.revoke({ generation })); if (!result.ok && !['stale', 'closing'].includes(result.code)) throw failure(result.code); return; }
      if (this.closed) throw failure('closing');
      const state = this.state(value.account);
      if (state.uncertain) {
        await this.bounded(this.bridge.revoke({ generation }));
        if (generation === this.generation && this.stillCurrent(value.owner, state.account)) { state.error = failure('uncertain'); state.canReset = false; this.lease = { owner: value.owner, generation, state }; }
        return;
      }
      const result = await this.bounded(this.bridge.open({ account: clone(state.account), generation }));
      if (generation !== this.generation || !this.stillCurrent(value.owner, state.account)) return;
      this.acceptNotices(result.notices);
      if (result.ok) {
        if (typeof result.lease !== 'string' || !result.lease || result.lease.length > 256 || !revision(result.revision) || !['device', 'session'].includes(result.retention)) throw failure('invalid');
        const checked = engine(state.account, result.document).store.load(state.account, { kind: 'library', category: 'All', libraryId: '', parentId: '', parentType: '' });
        if (checked.error || new TextEncoder().encode(JSON.stringify(result.document)).byteLength > 524288) throw failure('preserved');
        state.document = clone(result.document);
        const loaded = engine(state.account, state.document);
        for (const [id, pending] of state.pending) {
          const choices = loaded.store.load(state.account, pending.scope).choices;
          for (const field of Object.keys(pending.patch) as Array<keyof LibraryChoices>) if (choices[field] === pending.patch[field]) { delete pending.patch[field]; delete pending.versions[field]; delete pending.owners[field]; }
          if (!Object.keys(pending.patch).length) state.pending.delete(id);
        }
        state.retention = result.retention; state.error = undefined; state.canReset = false;
        this.lease = { owner: value.owner, generation, id: result.lease, revision: result.revision, state };
      } else {
        state.error = failure(result.code); if (result.code === 'uncertain') state.uncertain = true; state.canReset = result.canReset === true;
        const resettable = result as Extract<BrowseOpenResult, { canReset: true }>;
        if (state.canReset && (!['corrupt', 'unsupported'].includes(result.code) || !resettable.lease || !revision(resettable.revision))) throw failure('invalid');
        if (state.canReset) state.retention = 'device';
        this.lease = { owner: value.owner, generation, id: state.canReset ? resettable.lease : undefined, revision: state.canReset ? resettable.revision : undefined, state };
      }
    })().catch(error => {
      if (value && generation === this.generation && this.stillCurrent(value.owner, value.account)) {
        const state = this.state(value.account); state.error = state.uncertain ? failure('uncertain') : error instanceof LibraryPreferenceError ? error : failure('unavailable'); state.canReset = false;
        this.lease = { owner: value.owner, generation, state };
      }
    });
    this.activation = work; return work;
  }
  private async ensure(account: BrowseAccount, admission?: Admission): Promise<Lease> {
    const current = this.current(); if (!current || !this.stillCurrent(current.owner, account)) throw failure(this.closed ? 'closing' : 'stale');
    if (admission && !this.owns(admission)) throw failure('stale');
    if (this.activation) await this.activation;
    if (admission && !this.owns(admission)) throw failure('stale');
    if (!this.lease || this.lease.owner !== current.owner || key(this.lease.state.account) !== key(account)) { if (admission) throw failure('stale'); await this.activate(current); }
    const lease = this.lease;
    if (!lease || !this.stillCurrent(current.owner, account) || lease.owner !== current.owner || admission && (!this.owns(admission, lease) || lease.generation !== admission.generation)) throw failure('stale');
    return lease;
  }
  private snapshot(state: AccountState, scope: LibraryScope): BrowsePreferenceSnapshot {
    const local = engine(state.account, state.document), active = this.lease?.state === state ? { owner: this.lease.owner, generation: this.lease.generation } : undefined;
    let previousPending = false;
    for (const pending of state.pending.values()) {
      const patch: Partial<LibraryChoices> = {};
      for (const field of Object.keys(pending.patch) as Array<keyof LibraryChoices>) {
        if (active && this.sameAdmission(pending.owners[field], active)) Object.assign(patch, { [field]: pending.patch[field] }); else previousPending = true;
      }
      try { if (Object.keys(patch).length) local.store.update(state.account, pending.scope, patch); } catch { /* load exposes local schema/read limits. */ }
    }
    const snapshot = local.store.load(state.account, scope);
    return { ...snapshot, error: state.error ?? snapshot.error, canReset: state.error ? state.canReset : snapshot.canReset, retention: state.retention, previousPending, canRetry: !state.uncertain };
  }
  async load(account: BrowseAccount, scope: LibraryScope): Promise<BrowsePreferenceSnapshot> { await this.queue; return this.readSnapshot(account, scope); }
  private async readSnapshot(account: BrowseAccount, scope: LibraryScope): Promise<BrowsePreferenceSnapshot> {
    const state = this.state(account);
    try { await this.ensure(account); }
    catch (error) { return { ...this.snapshot(state, scope), error: error instanceof LibraryPreferenceError ? error : failure('unavailable'), canReset: false }; }
    return this.snapshot(state, scope);
  }
  private enqueue<T>(body: () => Promise<T>): Promise<T> { const work = this.queue.then(body); this.queue = work.catch(() => undefined); return work; }
  async update(account: BrowseAccount, scope: LibraryScope, patch: Partial<LibraryChoices>): Promise<void> {
    engine(account).store.update(account, scope, patch);
    const admission = this.admit(account), state = this.state(account), id = scopeKey(scope), previous = state.pending.get(id);
    const versions = { ...previous?.versions }, owners = { ...previous?.owners };
    for (const field of Object.keys(patch) as Array<keyof LibraryChoices>) { versions[field] = ++this.editVersion; owners[field] = { ...admission }; }
    state.pending.set(id, { scope: clone(scope), patch: { ...previous?.patch, ...patch }, versions, owners });
    return this.enqueue(() => this.flush(account, admission)).catch(error => {
      if (this.owns(admission)) { state.error = error instanceof LibraryPreferenceError ? error : failure('uncertain'); if (state.error instanceof DesktopBrowseError && state.error.code === 'uncertain') state.uncertain = true; if (!(state.error instanceof DesktopBrowseError) || !['corrupt', 'unsupported'].includes(state.error.code)) state.canReset = false; }
      throw error;
    });
  }
  private async flush(account: BrowseAccount, admission: Admission): Promise<void> {
    const lease = await this.ensure(account, admission), state = lease.state;
    if (state.error) throw state.error;
    if (!this.bridge || !lease.id || !lease.revision) throw failure('unavailable');
    const captured: Array<readonly [string, Pending]> = [];
    for (const [id, edit] of state.pending) {
      const selected = clone(edit);
      for (const field of Object.keys(selected.patch) as Array<keyof LibraryChoices>) if (!this.sameAdmission(selected.owners[field], admission)) { delete selected.patch[field]; delete selected.versions[field]; delete selected.owners[field]; }
      if (Object.keys(selected.patch).length) captured.push([id, selected]);
    }
    if (!captured.length) return;
    const local = engine(account, state.document); for (const [, edit] of captured) local.store.update(account, edit.scope, edit.patch);
    const document = local.document();
    if (new TextEncoder().encode(JSON.stringify(document)).byteLength > 524288) { state.error = failure('limit'); throw state.error; }
    let result;
    try { result = await this.bounded(this.bridge.commit({ lease: lease.id, expectedRevision: lease.revision, document })); }
    catch { if (!this.owns(admission, lease)) throw failure('stale'); state.error = failure('uncertain'); state.uncertain = true; state.canReset = false; throw state.error; }
    if (!this.owns(admission, lease) || !this.stillCurrent(lease.owner, account)) throw failure('stale');
    if (!result.ok) { state.error = failure(result.code); if (result.code === 'uncertain') state.uncertain = true; state.canReset = false; throw state.error; }
    if (!revision(result.revision)) { state.error = failure('uncertain'); state.uncertain = true; throw state.error; }
    state.document = clone(document); lease.revision = result.revision; state.error = undefined; state.canReset = false;
    for (const [id, edit] of captured) {
      const pending = state.pending.get(id); if (!pending) continue;
      for (const field of Object.keys(edit.patch) as Array<keyof LibraryChoices>) if (pending.versions[field] === edit.versions[field]) { delete pending.patch[field]; delete pending.versions[field]; delete pending.owners[field]; }
      if (!Object.keys(pending.patch).length) state.pending.delete(id);
    }
  }
  async retry(account: BrowseAccount, scope: LibraryScope): Promise<BrowsePreferenceSnapshot> {
    const admission = this.admit(account), state = this.state(account), captured = [...state.pending].map(([id, value]) => [id, clone(value)] as const);
    return this.enqueue(async () => {
      if (!this.owns(admission)) throw failure('stale');
      if (state.uncertain) return this.readSnapshot(account, scope);
      const opening = this.activate(this.current()), generation = this.generation; await opening;
      const fresh = { owner: admission.owner, generation }; if (!this.owns(fresh)) throw failure('stale');
      // Only this explicit Retry may move earlier pending field versions onto a fresh lease.
      for (const [id, edit] of captured) {
        const pending = state.pending.get(id); if (!pending) continue;
        for (const field of Object.keys(edit.patch) as Array<keyof LibraryChoices>) if (pending.versions[field] === edit.versions[field]) pending.owners[field] = { ...fresh };
      }
      try { await this.flush(account, fresh); } catch { if (!this.owns(fresh)) throw failure('stale'); }
      return this.readSnapshot(account, scope);
    });
  }
  async reset(account: BrowseAccount): Promise<void> {
    const admission = this.admit(account);
    return this.enqueue(async () => {
      const lease = await this.ensure(account, admission), state = lease.state, beforeReset = this.editVersion;
      if (!this.bridge || !lease.id || !lease.revision || state.error && !state.canReset) throw state.error ?? failure('unavailable');
      let result;
      try { result = await this.bounded(this.bridge.reset({ lease: lease.id, expectedRevision: lease.revision })); }
      catch { if (!this.owns(admission, lease)) throw failure('stale'); state.error = failure('uncertain'); state.uncertain = true; state.canReset = false; throw state.error; }
      if (!this.owns(admission, lease) || !this.stillCurrent(lease.owner, account)) throw failure('stale');
      if (!result.ok) { state.error = failure(result.code); if (result.code === 'uncertain') state.uncertain = true; if (result.code !== 'io') state.canReset = false; throw state.error; }
      if (!revision(result.revision)) { state.error = failure('uncertain'); state.uncertain = true; state.canReset = false; throw state.error; }
      state.document = undefined;
      for (const [id, pending] of state.pending) {
        for (const field of Object.keys(pending.patch) as Array<keyof LibraryChoices>) if ((pending.versions[field] ?? 0) <= beforeReset) { delete pending.patch[field]; delete pending.versions[field]; delete pending.owners[field]; }
        if (!Object.keys(pending.patch).length) state.pending.delete(id);
      }
      state.error = undefined; state.canReset = false; this.lease = undefined; await this.activate(this.current());
    });
  }
  /** Host owns remembered-file cleanup. Session map cleanup follows only a committed connection removal. */
  async removeAccount(account: BrowseAccount): Promise<void> {
    const callOwner = this.current()?.owner, callGeneration = this.generation;
    return this.enqueue(async () => {
    if (this.closed || callOwner !== this.current()?.owner || callGeneration !== this.generation) { this.acceptNotices([{ id: 'session-cleanup-stale-' + callGeneration, accountId: 'local', count: 1, code: 'io' }]); throw failure('stale'); }
    const savedCurrent = this.current(), generation = ++this.generation; this.lease = undefined;
    this.accounts.delete(key(account));
    try {
      if (!this.bridge || this.closed) return;
      const result = await this.bounded(this.bridge.open({ account: { server: normalizeServer(account.server), userId: account.userId }, generation }));
      if (generation !== this.generation || this.current()?.owner !== savedCurrent?.owner || this.closed) throw failure('stale');
      this.acceptNotices(result.notices);
      if (!result.ok) { this.acceptNotices([{ id: 'session-cleanup-' + generation, accountId: 'local', count: 1, code: result.code === 'preserved' ? 'preserved' : result.code === 'uncertain' ? 'uncertain' : 'io' }]); throw failure(result.code); }
      if (result.ok && result.retention === 'session') {
        const reset = await this.bounded(this.bridge.reset({ lease: result.lease, expectedRevision: result.revision }));
        if (!reset.ok) throw failure(reset.code);
      }
    } catch (error) { this.acceptNotices([{ id: 'session-cleanup-' + generation, accountId: 'local', count: 1, code: error instanceof DesktopBrowseError && error.code === 'preserved' ? 'preserved' : error instanceof DesktopBrowseError && error.code === 'uncertain' ? 'uncertain' : 'io' }]); throw error instanceof LibraryPreferenceError ? error : failure('unavailable'); } finally {
      if (generation === this.generation && !this.closed && this.current()?.owner === savedCurrent?.owner) await this.activate(this.current());
    }
    });
  }
  drain(): Promise<void> { return this.queue.then(() => this.activation).then(() => undefined); }
  close(): Promise<void> {
    if (this.closingWork) return this.closingWork;
    this.closed = true; this.lease = undefined; const generation = ++this.generation;
    this.disposeNotices?.(); this.disposeNotices = undefined; this.noticeHandler = undefined;
    this.closingWork = (async () => {
      if (this.bridge) { const result = await this.bounded(this.bridge.revoke({ generation })); if (!result.ok && !['closing', 'stale'].includes(result.code)) throw failure(result.code); }
      await this.drain();
    })();
    return this.closingWork;
  }
}

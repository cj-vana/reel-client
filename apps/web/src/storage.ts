import { normalizeServer } from './api.ts';
import { type Account } from './types.ts';

export interface StorageLike { readonly persistent?: boolean; getItem(key: string): string | null; setItem(key: string, value: string): void; removeItem(key: string): void }
export interface ConnectionSnapshot { accounts: Account[]; activeId: string | null }
export interface ConnectionPersistence { snapshot: ConnectionSnapshot; save(snapshot: ConnectionSnapshot): Promise<void> }
export interface BrowserRecovery { reason: 'read' | 'invalid' | 'unavailable'; message: string; pendingRemember: number; pendingRemovals: number; canReplace: boolean }
const ACCOUNT_KEY = 'reel.connections.v1';
type Intent = { kind: 'add'; account: Account } | { kind: 'switch' | 'remove'; id: string };
const messages = {
  read: 'Saved connections could not be read. They have not been changed. New connections can be used for this session while you retry recovery.',
  invalid: 'Saved connection data could not be read safely. It has not been changed. Retry recovery, or explicitly replace it with the connections shown here.',
  unavailable: 'Browser storage is unavailable. Connections can be used for this session only. Reopen Reel when storage is permitted.'
};
class SavedReadError extends Error {
  readonly reason: 'read' | 'invalid' | 'unavailable';
  constructor(reason: 'read' | 'invalid' | 'unavailable') { super(messages[reason]); this.reason = reason; }
}

export class Connections {
  private accounts: Account[] = [];
  activeId: string | null = null;
  revision = 0;
  onChange?: () => void;
  private storage: StorageLike;
  private pending: Promise<void> = Promise.resolve();
  private closed = false;
  private persistence?: ConnectionPersistence;
  private issue: BrowserRecovery['reason'] | null = null;
  private local = new Map<string, Account | null>();
  private selectedLocally = false;
  constructor(storage: StorageLike, persistence?: ConnectionPersistence) {
    this.persistence = persistence; this.storage = storage;
    if (persistence) {
      // The desktop provider owns validation, encrypted revisions and quarantine.
      try {
        const snapshot = persistence.snapshot;
        if (snapshot && typeof snapshot === 'object') {
          if (Array.isArray(snapshot.accounts)) this.accounts = snapshot.accounts.filter(validDesktopAccount).map(account => ({ ...account, remember: true }));
          if (typeof snapshot.activeId === 'string' && this.accounts.some(account => account.id === snapshot.activeId)) this.activeId = snapshot.activeId;
        }
      } catch { /* Native provider owns any recovery state; no browser write is attempted. */ }
      return;
    }
    try { const saved = this.readBrowser(); this.accounts = saved.accounts; this.activeId = saved.activeId; }
    catch (error) { this.issue = error instanceof SavedReadError ? error.reason : 'read'; }
  }
  get all(): readonly Account[] { return this.accounts; }
  get active(): Account | null { return this.accounts.find(account => account.id === this.activeId) ?? null; }
  get canRemember(): boolean { return this.persistence !== undefined || this.issue === null; }
  get recovery(): BrowserRecovery | null {
    if (this.persistence || !this.issue) return null;
    return { reason: this.issue, message: messages[this.issue], pendingRemember: [...this.local.values()].filter(account => account?.remember).length, pendingRemovals: [...this.local.values()].filter(account => account === null).length, canReplace: this.storage.persistent !== false };
  }
  add(account: Account): void | Promise<void> { return this.mutate({ kind: 'add', account }); }
  switch(id: string): void | Promise<void> { return this.mutate({ kind: 'switch', id }); }
  remove(id: string): void | Promise<void> { return this.mutate({ kind: 'remove', id }); }
  private mutate(intent: Intent): void | Promise<void> {
    this.assertOpen();
    if (!this.persistence) { this.commitBrowser(intent); return; }
    const persist = this.persistence;
    const operation = this.pending.then(async () => {
      this.assertOpen();
      const next = applyIntent({ accounts: this.accounts, activeId: this.activeId }, intent);
      await persist.save(remembered(next)); this.publish(next);
    });
    this.pending = operation.catch(() => undefined); return operation;
  }
  private assertOpen(): void { if (this.closed) throw new Error('Reel is closing. Reopen it to continue.'); }
  private readBrowser(): ConnectionSnapshot {
    if (this.storage.persistent === false) throw new SavedReadError('unavailable');
    let raw: string | null;
    try { raw = this.storage.getItem(ACCOUNT_KEY); } catch { throw new SavedReadError('read'); }
    if (raw === null) return { accounts: [], activeId: null };
    try { return validatedSnapshot(JSON.parse(raw)); } catch { throw new SavedReadError('invalid'); }
  }
  private intentsWith(intent: Intent): Map<string, Account | null> {
    const local = new Map(this.local);
    if (intent.kind === 'add') local.set(intent.account.id, { ...intent.account });
    if (intent.kind === 'remove') local.set(intent.id, null);
    return local;
  }
  private merged(saved: ConnectionSnapshot, local: Map<string, Account | null>): ConnectionSnapshot {
    const accounts = new Map(saved.accounts.map(account => [account.id, account]));
    for (const [id, account] of local) { if (account) accounts.set(id, account); else accounts.delete(id); }
    const selected = this.selectedLocally ? this.activeId : saved.activeId;
    return { accounts: [...accounts.values()], activeId: selected !== null && accounts.has(selected) ? selected : null };
  }
  private accepted(next: ConnectionSnapshot, local: Map<string, Account | null>, durable: boolean): void {
    // Successful durable writes consume remembered changes. Session-only accounts
    // stay in memory and never have their token included in the saved snapshot.
    this.local = durable ? new Map([...local].filter(([, account]) => account && !account.remember)) : local;
    this.selectedLocally = true; this.publish(next);
  }
  private commitBrowser(intent: Intent): void {
    const local = this.intentsWith(intent);
    let saved: ConnectionSnapshot;
    try { saved = this.readBrowser(); }
    catch (error) {
      this.issue = error instanceof SavedReadError ? error.reason : 'read';
      const next = applyIntent({ accounts: this.accounts, activeId: this.activeId }, intent);
      this.accepted(next, local, false); return;
    }
    const next = applyIntent(this.merged(saved, this.local), intent);
    this.writeBrowser(next); this.issue = null; this.accepted(next, local, true);
  }
  private writeBrowser(next: ConnectionSnapshot): void {
    try { this.storage.setItem(ACCOUNT_KEY, JSON.stringify(remembered(next))); }
    catch { throw new Error('Reel could not save this change. The previous saved connections have not been replaced. Check browser storage and try again.'); }
  }
  retrySaved(): void {
    this.assertOpen(); if (this.persistence) throw new Error('Desktop secure storage must be recovered by reopening the native app.');
    let saved: ConnectionSnapshot;
    try { saved = this.readBrowser(); }
    catch (error) { this.issue = error instanceof SavedReadError ? error.reason : 'read'; throw new Error(messages[this.issue]); }
    const next = this.merged(saved, this.local), desired = remembered(next);
    const changedAccounts = JSON.stringify(desired.accounts) !== JSON.stringify(saved.accounts);
    const changedRememberedSelection = desired.activeId !== null && desired.activeId !== saved.activeId;
    if (changedAccounts || changedRememberedSelection) this.writeBrowser(next);
    this.issue = null; this.accepted(next, this.local, true);
  }
  replaceSaved(): void {
    this.assertOpen(); if (this.persistence || !this.issue || this.storage.persistent === false) throw new Error('This saved store cannot be replaced here.');
    const next = { accounts: this.accounts, activeId: this.activeId };
    this.writeBrowser(next); this.issue = null; this.accepted(next, this.local, true);
  }
  private publish(next: ConnectionSnapshot): void { this.accounts = next.accounts; this.activeId = next.activeId; this.revision++; this.onChange?.(); }
  close(): void { this.closed = true; }
  drain(): Promise<void> { return this.pending; }
}

function applyIntent(snapshot: ConnectionSnapshot, intent: Intent): ConnectionSnapshot {
  if (intent.kind === 'add') return { accounts: snapshot.accounts.filter(account => account.id !== intent.account.id).concat({ ...intent.account }), activeId: intent.account.id };
  if (intent.kind === 'switch') {
    if (!snapshot.accounts.some(account => account.id === intent.id)) throw new Error('This connection is no longer available.');
    return { accounts: snapshot.accounts, activeId: intent.id };
  }
  const accounts = snapshot.accounts.filter(account => account.id !== intent.id);
  return { accounts, activeId: snapshot.activeId === intent.id ? accounts[0]?.id ?? null : snapshot.activeId };
}
function remembered(snapshot: ConnectionSnapshot): ConnectionSnapshot {
  const accounts = snapshot.accounts.filter(account => account.remember);
  return { accounts, activeId: accounts.some(account => account.id === snapshot.activeId) ? snapshot.activeId : null };
}
function exactKeys(value: Record<string, unknown>, keys: string[]): boolean { return Object.keys(value).length === keys.length && Object.keys(value).every(key => keys.includes(key)); }
function validDesktopAccount(value: unknown): value is Account {
  if (!value || typeof value !== 'object') return false;
  const account = value as Record<string, unknown>;
  if (!['id', 'server', 'token', 'userId', 'name', 'serverName'].every(key => typeof account[key] === 'string') || !account.token || !account.userId) return false;
  try { normalizeServer(account.server as string); return true; } catch { return false; }
}
function validatedSnapshot(value: unknown): ConnectionSnapshot {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid snapshot');
  const data = value as Record<string, unknown>;
  if (!exactKeys(data, ['accounts', 'activeId']) || !Array.isArray(data.accounts) || !(data.activeId === null || typeof data.activeId === 'string')) throw new Error('Unsupported snapshot');
  const ids = new Set<string>(); const accounts: Account[] = [];
  for (const value of data.accounts) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid account');
    const account = value as Record<string, unknown>;
    if (!exactKeys(account, ['id', 'server', 'token', 'userId', 'name', 'serverName', 'remember']) || !['id', 'server', 'token', 'userId', 'name', 'serverName'].every(key => typeof account[key] === 'string') || !account.id || !account.token || !account.userId || account.remember !== true || ids.has(account.id as string)) throw new Error('Unsupported account');
    normalizeServer(account.server as string); // Validate without rewriting one half of an acknowledged credential tuple.
    ids.add(account.id as string); accounts.push({ ...(account as unknown as Account) });
  }
  if (data.activeId !== null && !accounts.some(account => account.id === data.activeId)) throw new Error('Invalid selection');
  return { accounts, activeId: data.activeId as string | null };
}
export function deviceId(storage: StorageLike): string {
  const key = 'reel.device.v1'; let id = storage.getItem(key);
  if (!id || !/^[a-z0-9-]{12,80}$/i.test(id)) { const bytes = new Uint8Array(16); crypto.getRandomValues(bytes); id = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join(''); storage.setItem(key, id); }
  return id;
}
export function browserStorage(): StorageLike {
  try {
    const key = 'reel.storage.probe'; localStorage.setItem(key, '1'); localStorage.removeItem(key);
    return { persistent: true, getItem: key => localStorage.getItem(key), setItem: (key, value) => localStorage.setItem(key, value), removeItem: key => localStorage.removeItem(key) };
  } catch {
    const memory = new Map<string, string>();
    return { persistent: false, getItem: key => memory.get(key) ?? null, setItem: (key, value) => { memory.set(key, value); }, removeItem: key => { memory.delete(key); } };
  }
}

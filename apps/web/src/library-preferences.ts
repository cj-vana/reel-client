import { normalizeServer } from './api.ts';
import { defaultLibraryChoices, libraryCategories, librarySorts, type LibraryChoices, type LibraryScope } from './library-query.ts';
import type { StorageLike } from './storage.ts';

type BrowseAccount = { server: string; userId: string };
type ChoicesPatch = Partial<LibraryChoices>;
interface Entry { scope: LibraryScope; choices: LibraryChoices }
interface Document { schema: 1; account: BrowseAccount; entries: Entry[] }
interface PendingEntry { scope: LibraryScope; patch: ChoicesPatch }
export interface LibraryPreferenceSnapshot { choices: LibraryChoices; error?: LibraryPreferenceError; canReset: boolean }
export class LibraryPreferenceError extends Error {
  readonly foreign: boolean;
  readonly preserve: boolean;
  constructor(message: string, foreign = false, preserve = false) {
    super(message); this.name = 'LibraryPreferenceError'; this.foreign = foreign; this.preserve = foreign || preserve;
  }
}
const PREFIX = 'reel.browse.v1.';
const hasOwn = (value: object, key: string): boolean => Object.prototype.hasOwnProperty.call(value, key);
const MAX_SCOPES = 128;
const MAX_DOCUMENT_LENGTH = 524288;
const isObject = (value: unknown): value is Record<string, unknown> => !!value && typeof value === 'object' && !Array.isArray(value);
const byteLength = (value: string): number => new TextEncoder().encode(value).byteLength;
function accountIdentity(account: BrowseAccount): BrowseAccount {
  const server = normalizeServer(account.server);
  if (!account.userId || byteLength(account.userId) > 512 || byteLength(server) > 2048) throw new LibraryPreferenceError('This connection cannot save browse preferences.');
  return { server, userId: account.userId };
}
function accountKey(account: BrowseAccount): string { const value = accountIdentity(account); return PREFIX + JSON.stringify([value.server, value.userId]); }
function scopeKey(scope: LibraryScope): string { return JSON.stringify([scope.kind, scope.libraryId, scope.category, scope.parentId, scope.parentType]); }
const scopeFields = ['kind', 'category', 'libraryId', 'parentId', 'parentType'];
const choiceFields = ['sort', 'direction', 'genreId', 'watchStatus', 'favoritesOnly', 'view'];
function exactKeys(value: Record<string, unknown>, keys: string[]): boolean {
  return Object.keys(value).length === keys.length && keys.every(key => hasOwn(value, key));
}
function validScope(value: unknown): value is LibraryScope {
  if (!isObject(value) || !exactKeys(value, scopeFields)) return false;
  return typeof value.kind === 'string' && ['library', 'search', 'favorites', 'music', 'photos', 'books', 'container'].includes(value.kind)
    && libraryCategories.includes(value.category as LibraryScope['category'])
    && ['libraryId', 'parentId', 'parentType'].every(key => typeof value[key] === 'string' && byteLength(value[key]) <= 512)
    && (value.kind === 'container' ? !!value.parentId && !!value.parentType : !value.parentId && !value.parentType);
}
function validPatch(value: unknown): value is ChoicesPatch {
  if (!isObject(value) || Object.keys(value).some(key => !choiceFields.includes(key))) return false;
  return (!hasOwn(value, 'sort') || librarySorts.includes(value.sort as LibraryChoices['sort']))
    && (!hasOwn(value, 'direction') || value.direction === 'Ascending' || value.direction === 'Descending')
    && (!hasOwn(value, 'genreId') || typeof value.genreId === 'string' && byteLength(value.genreId) <= 512)
    && (!hasOwn(value, 'watchStatus') || typeof value.watchStatus === 'string' && ['Any', 'Watched', 'Unwatched'].includes(value.watchStatus))
    && (!hasOwn(value, 'favoritesOnly') || typeof value.favoritesOnly === 'boolean')
    && (!hasOwn(value, 'view') || value.view === 'grid' || value.view === 'list');
}
function validChoices(value: unknown): value is LibraryChoices { return isObject(value) && exactKeys(value, choiceFields) && validPatch(value); }
function ownDocument(value: unknown, account: BrowseAccount): Document {
  // Recognizable foreign data is never overwritten, reset or removed.
  if (isObject(value) && isObject(value.account) && typeof value.account.server === 'string' && typeof value.account.userId === 'string') {
    if (value.account.server !== account.server || value.account.userId !== account.userId) throw new LibraryPreferenceError('These saved preferences belong to a different connection. They have been left untouched.', true);
  }
  if (!isObject(value) || !exactKeys(value, ['schema', 'account', 'entries']) || value.schema !== 1
      || !isObject(value.account) || !exactKeys(value.account, ['server', 'userId'])
      || value.account.server !== account.server || value.account.userId !== account.userId
      || !Array.isArray(value.entries) || value.entries.length > MAX_SCOPES) throw new LibraryPreferenceError('Saved browse preferences could not be read. Retry or reset this connection’s preferences.');
  const seen = new Set<string>();
  for (const entry of value.entries) {
    if (!isObject(entry) || !exactKeys(entry, ['scope', 'choices']) || !validScope(entry.scope) || !validChoices(entry.choices)) throw new LibraryPreferenceError('Saved browse preferences could not be read. Retry or reset this connection’s preferences.');
    const key = scopeKey(entry.scope);
    if (seen.has(key)) throw new LibraryPreferenceError('Saved browse preferences contain conflicting entries. They have been left untouched.');
    seen.add(key);
  }
  return value as unknown as Document;
}

/** Noncredential preferences. Failed writes keep a field-level patch for explicit Retry. */
export class LibraryPreferences {
  private readonly storage: StorageLike;
  private readonly pending = new Map<string, Map<string, PendingEntry>>();
  private readonly cached = new Map<string, Document>();
  private readonly failures = new Map<string, LibraryPreferenceError>();
  constructor(storage: StorageLike) { this.storage = storage; }
  private read(account: BrowseAccount): Document {
    const identity = accountIdentity(account), key = accountKey(identity);
    let raw: string | null;
    try { raw = this.storage.getItem(key); }
    catch { throw new LibraryPreferenceError('Browse preferences are unavailable. Your existing settings have been left untouched.', false, true); }
    if (raw === null) return { schema: 1, account: identity, entries: [] };
    if (raw.length > MAX_DOCUMENT_LENGTH) throw new LibraryPreferenceError('Saved browse preferences are too large to read safely. They have been left untouched.', false, true);
    let parsed: unknown;
    try { parsed = JSON.parse(raw); }
    catch { throw new LibraryPreferenceError('Saved browse preferences could not be read. Retry or reset this connection’s preferences.'); }
    return ownDocument(parsed, identity);
  }
  load(account: BrowseAccount, scope: LibraryScope): LibraryPreferenceSnapshot {
    if (!validScope(scope)) throw new LibraryPreferenceError('This library cannot save browse preferences.');
    const key = accountKey(account), id = scopeKey(scope);
    let document = this.cached.get(key), error = this.failures.get(key);
    try { document = this.read(account); this.cached.set(key, document); }
    catch (failure) { error = failure instanceof LibraryPreferenceError ? failure : new LibraryPreferenceError('Browse preferences are unavailable.'); }
    const stored = document?.entries.find(entry => scopeKey(entry.scope) === id)?.choices;
    return { choices: { ...defaultLibraryChoices(), ...stored, ...this.pending.get(key)?.get(id)?.patch }, error, canReset: !error?.preserve };
  }
  update(account: BrowseAccount, scope: LibraryScope, patch: ChoicesPatch): void {
    if (!validScope(scope) || !validPatch(patch)) throw new LibraryPreferenceError('This browse preference is invalid.');
    const key = accountKey(account), id = scopeKey(scope), entries = this.pending.get(key) ?? new Map<string, PendingEntry>();
    const previous = entries.get(id);
    entries.set(id, { scope: { ...scope }, patch: { ...previous?.patch, ...patch } }); this.pending.set(key, entries);
    this.flush(account);
  }
  flush(account: BrowseAccount): void {
    const key = accountKey(account);
    try {
      const document = this.read(account), pending = this.pending.get(key);
      if (!pending?.size) { this.cached.set(key, document); this.failures.delete(key); return; }
      const entries = document.entries.map(entry => ({ scope: { ...entry.scope }, choices: { ...entry.choices } }));
      for (const [id, edit] of pending) {
        const existing = entries.find(entry => scopeKey(entry.scope) === id);
        if (existing) existing.choices = { ...existing.choices, ...edit.patch };
        else entries.push({ scope: { ...edit.scope }, choices: { ...defaultLibraryChoices(), ...edit.patch } });
      }
      if (entries.length > MAX_SCOPES) throw new LibraryPreferenceError('This connection has too many saved library views. Reset its browse preferences to save a new view.');
      const next: Document = { ...document, entries };
      const encoded = JSON.stringify(next);
      if (encoded.length > MAX_DOCUMENT_LENGTH) throw new LibraryPreferenceError('These browse choices exceed the storage limit. Existing preferences have been kept. Choose a shorter filter or reset this connection’s browse preferences.');
      try { this.storage.setItem(key, encoded); }
      catch { throw new LibraryPreferenceError('Browse preferences could not be saved. Retry when storage is available.'); }
      this.cached.set(key, next); this.pending.delete(key); this.failures.delete(key);
    } catch (failure) {
      const error = failure instanceof LibraryPreferenceError ? failure : new LibraryPreferenceError('Browse preferences are unavailable.');
      this.failures.set(key, error); throw error;
    }
  }
  retry(account: BrowseAccount, scope: LibraryScope): LibraryPreferenceSnapshot {
    try { this.flush(account); }
    catch (error) {
      const snapshot = this.load(account, scope);
      return { ...snapshot, error: error instanceof LibraryPreferenceError ? error : new LibraryPreferenceError('Browse preferences are unavailable.'), canReset: !(error instanceof LibraryPreferenceError && error.preserve) };
    }
    return this.load(account, scope);
  }
  /** Call only after the user confirms resetting this exact connection. */
  reset(account: BrowseAccount): void {
    const key = accountKey(account);
    try { this.read(account); } catch (error) { if (error instanceof LibraryPreferenceError && error.preserve) throw error; }
    try { this.storage.removeItem(key); }
    catch { throw new LibraryPreferenceError('Browse preferences could not be reset. Existing data has been left untouched.'); }
    this.pending.delete(key); this.cached.delete(key); this.failures.delete(key);
  }
  /** Call only after connection removal has committed successfully. */
  removeAccount(account: BrowseAccount): void { this.reset(account); }
}

import test from 'node:test';
import assert from 'node:assert/strict';
import { LibraryPreferences, LibraryPreferenceError } from '../src/library-preferences.ts';
import { type LibraryScope } from '../src/library-query.ts';
import type { StorageLike } from '../src/storage.ts';

const account = { server: 'https://media.example/jellyfin', userId: 'one' };
const scope = (changes: Partial<LibraryScope> = {}): LibraryScope => ({ kind: 'library', category: 'All', libraryId: '', parentId: '', parentType: '', ...changes });
function memory(): { storage: StorageLike; values: Map<string, string>; writes: () => number; removals: () => number } {
  const values = new Map<string, string>(); let writes = 0, removals = 0;
  return { values, writes: () => writes, removals: () => removals, storage: { getItem: key => values.get(key) ?? null,
    setItem: (key, value) => { writes++; values.set(key, value); }, removeItem: key => { removals++; values.delete(key); } } };
}
test('first read is empty and side-effect free; saved choices survive a fresh store', () => {
  const state = memory(), store = new LibraryPreferences(state.storage);
  assert.equal(store.load(account, scope()).choices.sort, 'SortName'); assert.equal(state.writes(), 0);
  store.update(account, scope(), { sort: 'DateCreated', direction: 'Descending', favoritesOnly: true, view: 'list' });
  const restored = new LibraryPreferences(state.storage).load(account, scope());
  assert.equal(restored.error, undefined); assert.equal(restored.choices.sort, 'DateCreated'); assert.equal(restored.choices.view, 'list');
  assert.equal(restored.choices.favoritesOnly, true); assert.equal(state.values.size, 1);
});
test('canonical origin aliases share preferences while base path, user, library, category and parent stay isolated', () => {
  const state = memory(), store = new LibraryPreferences(state.storage);
  const film = scope({ category: 'Movies', libraryId: 'library-one' });
  store.update(account, film, { genreId: 'comedy', watchStatus: 'Unwatched' });
  assert.equal(store.load({ ...account, server: 'https://MEDIA.example:443/jellyfin/' }, film).choices.genreId, 'comedy');
  for (const [otherAccount, otherScope] of [
    [{ ...account, server: 'https://media.example/other' }, film], [{ ...account, userId: 'two' }, film],
    [account, { ...film, libraryId: 'library-two' }], [account, { ...film, category: 'Series' }],
    [account, scope({ kind: 'container', parentId: 'box-one', parentType: 'BoxSet' })]
  ] as const) assert.equal(store.load(otherAccount, otherScope).choices.genreId, '');
});
test('an unreadable document preserves bytes and view-only recovery cannot overwrite restored sort/filter choices', () => {
  const state = memory(), store = new LibraryPreferences(state.storage);
  store.update(account, scope(), { sort: 'ProductionYear', direction: 'Descending', genreId: 'drama', watchStatus: 'Watched', favoritesOnly: true });
  const [key, original] = [...state.values.entries()][0]; state.values.set(key, '{broken');
  assert.ok(store.load(account, scope()).error);
  assert.throws(() => store.update(account, scope(), { view: 'list' }), LibraryPreferenceError);
  assert.equal(state.values.get(key), '{broken');
  assert.equal(store.load(account, scope()).choices.view, 'list');
  state.values.set(key, original);
  const recovered = store.retry(account, scope());
  assert.equal(recovered.error, undefined);
  assert.deepEqual(recovered.choices, { sort: 'ProductionYear', direction: 'Descending', genreId: 'drama', watchStatus: 'Watched', favoritesOnly: true, view: 'list' });
});
test('quota refusal keeps stored bytes and all pending field edits until a successful explicit Retry', () => {
  const state = memory(), store = new LibraryPreferences(state.storage);
  store.update(account, scope(), { sort: 'DateCreated' });
  const before = [...state.values.entries()]; const save = state.storage.setItem;
  state.storage.setItem = () => { throw new Error('Quota'); };
  assert.throws(() => store.update(account, scope(), { genreId: 'comedy' }), LibraryPreferenceError);
  assert.throws(() => store.update(account, scope(), { view: 'list' }), LibraryPreferenceError);
  assert.deepEqual([...state.values.entries()], before); assert.equal(store.load(account, scope()).choices.genreId, 'comedy');
  assert.ok(store.load(account, scope()).error, 'A successful read must not hide pending failed saves');
  assert.ok(store.retry(account, scope()).error); state.storage.setItem = save;
  const restored = store.retry(account, scope()); assert.equal(restored.error, undefined); assert.equal(restored.choices.genreId, 'comedy'); assert.equal(restored.choices.view, 'list');
});
test('read permission failure preserves data; recovery reapplies only the intended patch', () => {
  const state = memory(), store = new LibraryPreferences(state.storage);
  store.update(account, scope(), { favoritesOnly: true }); const get = state.storage.getItem;
  state.storage.getItem = () => { throw new Error('Denied'); };
  assert.ok(store.load(account, scope()).error); assert.throws(() => store.update(account, scope(), { direction: 'Descending' }), LibraryPreferenceError);
  assert.equal(store.load(account, scope()).canReset, false); assert.throws(() => store.reset(account), LibraryPreferenceError);
  state.storage.getItem = get; const restored = store.retry(account, scope());
  assert.equal(restored.error, undefined); assert.equal(restored.choices.favoritesOnly, true); assert.equal(restored.choices.direction, 'Descending');
});
test('recognizable foreign-account data is never overwritten, reset or removed', () => {
  const state = memory(), store = new LibraryPreferences(state.storage); store.update(account, scope(), { view: 'list' });
  const [key, raw] = [...state.values.entries()][0], foreign = JSON.parse(raw); foreign.account.userId = 'somebody-else';
  const original = JSON.stringify(foreign); state.values.set(key, original);
  const snapshot = store.load(account, scope()); assert.equal(snapshot.error?.foreign, true); assert.equal(snapshot.canReset, false);
  assert.throws(() => store.update(account, scope(), { view: 'grid' }), LibraryPreferenceError);
  assert.throws(() => store.reset(account), LibraryPreferenceError); assert.throws(() => store.removeAccount(account), LibraryPreferenceError);
  assert.equal(state.values.get(key), original); assert.equal(state.removals(), 0);
});
test('unknown schema, conflicting scopes and malformed choices remain recoverable without automatic repair writes', () => {
  for (const mutate of [
    (value: any) => { value.schema = 2; },
    (value: any) => { value.entries.push(value.entries[0]); },
    (value: any) => { value.entries[0].choices.direction = 'sideways'; },
    (value: any) => { value.entries[0].choices.extra = 'future'; }
  ]) {
    const state = memory(), store = new LibraryPreferences(state.storage); store.update(account, scope(), { view: 'list' });
    const [key, raw] = [...state.values.entries()][0], parsed = JSON.parse(raw); mutate(parsed); const invalid = JSON.stringify(parsed); state.values.set(key, invalid);
    const before = state.writes(); assert.ok(store.load(account, scope()).error); assert.equal(state.values.get(key), invalid); assert.equal(state.writes(), before);
  }
});
test('reset and committed-account cleanup touch only the exact account preference key', () => {
  const state = memory(), store = new LibraryPreferences(state.storage), other = { ...account, userId: 'two' };
  store.update(account, scope(), { genreId: 'one' }); store.update(other, scope(), { genreId: 'two' });
  state.values.set('unrelated', 'keep'); store.reset(account);
  assert.equal(store.load(account, scope()).choices.genreId, ''); assert.equal(store.load(other, scope()).choices.genreId, 'two');
  store.removeAccount(other); assert.equal(state.values.size, 1); assert.equal(state.values.get('unrelated'), 'keep');
});
test('failed removal retains cache/pending intent and sibling bytes until deletion succeeds', () => {
  const state = memory(), store = new LibraryPreferences(state.storage); store.update(account, scope(), { genreId: 'one' });
  const before = [...state.values.entries()], remove = state.storage.removeItem;
  state.storage.removeItem = () => { throw new Error('Denied'); };
  assert.throws(() => store.reset(account), LibraryPreferenceError); assert.deepEqual([...state.values.entries()], before);
  assert.equal(store.load(account, scope()).choices.genreId, 'one'); state.storage.removeItem = remove; store.removeAccount(account); assert.equal(state.values.size, 0);
});
test('invalid scope/patch and accepted maximum account sizes cannot erase another entry', () => {
  const state = memory(), store = new LibraryPreferences(state.storage);
  const maximum = { server: 'https://media.example/' + 'a'.repeat(2026), userId: 'u'.repeat(512) };
  assert.equal(new TextEncoder().encode(maximum.server).length, 2048);
  store.update(maximum, scope(), { view: 'list' }); assert.equal(store.load(maximum, scope()).choices.view, 'list');
  const before = [...state.values.entries()];
  assert.throws(() => store.update(account, { ...scope(), category: 'Unknown' } as never, { view: 'grid' }), LibraryPreferenceError);
  assert.throws(() => store.update(account, scope(), { token: 'not-allowed' } as never), LibraryPreferenceError);
  assert.throws(() => store.load({ ...account, userId: 'u'.repeat(513) }, scope()), LibraryPreferenceError);
  assert.deepEqual([...state.values.entries()], before);
});
test('an oversized unverifiable document is preserved by save, reset and account removal', () => {
  const state = memory(), store = new LibraryPreferences(state.storage); store.update(account, scope(), { view: 'list' });
  const key = [...state.values.keys()][0], original = JSON.stringify({ account: { ...account, userId: 'foreign' }, padding: 'x'.repeat(524288) }); state.values.set(key, original);
  assert.equal(store.load(account, scope()).canReset, false);
  assert.throws(() => store.update(account, scope(), { view: 'grid' }), LibraryPreferenceError);
  assert.throws(() => store.reset(account), LibraryPreferenceError); assert.throws(() => store.removeAccount(account), LibraryPreferenceError);
  assert.equal(state.values.get(key), original); assert.equal(state.removals(), 0);
});
test('the scope limit fails without truncation and retains existing choices', () => {
  const state = memory(), store = new LibraryPreferences(state.storage);
  for (let index = 0; index < 128; index++) store.update(account, scope({ libraryId: String(index) }), { view: 'list' });
  const before = [...state.values.entries()];
  assert.throws(() => store.update(account, scope({ libraryId: 'overflow' }), { view: 'list' }), /too many saved/);
  assert.deepEqual([...state.values.entries()], before); assert.equal(store.load(account, scope({ libraryId: '0' })).choices.view, 'list');
});
test('serialized size is checked before writing, including valid escaped values below the scope count limit', () => {
  const state = memory(), store = new LibraryPreferences(state.storage), sibling = { ...account, userId: 'sibling' };
  store.update(sibling, scope(), { view: 'list' });
  const siblingEntry = [...state.values.entries()][0]; let rejected = false;
  for (let index = 0; index < 128; index++) {
    const location = scope({ libraryId: '\0'.repeat(508) + String(index).padStart(4, '0') });
    const previous = [...state.values.entries()], writes = state.writes();
    try { store.update(account, location, { genreId: '\0'.repeat(512) }); }
    catch (error) {
      assert.match((error as Error).message, /exceed the storage limit/); rejected = true;
      assert.equal(state.writes(), writes); assert.deepEqual([...state.values.entries()], previous);
      const restored = new LibraryPreferences(state.storage).load(account, scope());
      assert.equal(restored.error, undefined); assert.equal(restored.canReset, true);
      const ownRaw = [...state.values.entries()].find(([key]) => key !== siblingEntry[0])![1];
      assert.ok(ownRaw.length > 500000 && ownRaw.length <= 524288, 'The near-limit durable document remains readable.');
      assert.equal(store.load(account, location).choices.genreId, '\0'.repeat(512), 'Rejected field intent remains available for recovery.');
      store.update(account, location, { genreId: '' });
      assert.equal(store.retry(account, location).error, undefined);
      assert.equal(new LibraryPreferences(state.storage).load(account, location).choices.genreId, '');
      assert.equal(state.values.get(siblingEntry[0]), siblingEntry[1]);
      break;
    }
    assert.equal(new LibraryPreferences(state.storage).load(account, location).error, undefined);
  }
  assert.equal(rejected, true, 'Exercise the byte-expansion boundary before128 scopes, rather than the scope count guard.');
});
test('malformed enum arrays and objects are rejected without coercion, writes or document repair', () => {
  for (const bad of [['Watched'], ['library'], { toString: 'Watched' }]) {
    const state = memory(), store = new LibraryPreferences(state.storage); store.update(account, scope(), { view: 'list' });
    const [key, raw] = [...state.values.entries()][0];
    assert.throws(() => store.update(account, scope(), { watchStatus: bad } as never), LibraryPreferenceError);
    assert.throws(() => store.update(account, { ...scope(), kind: bad } as never, { view: 'list' }), LibraryPreferenceError);
    assert.equal(state.values.get(key), raw);
    for (const field of ['watchStatus', 'kind']) {
      const document = JSON.parse(raw);
      if (field === 'kind') document.entries[0].scope.kind = bad;
      else document.entries[0].choices.watchStatus = bad;
      const malformed = JSON.stringify(document); state.values.set(key, malformed); const writes = state.writes();
      assert.ok(new LibraryPreferences(state.storage).load(account, scope()).error);
      assert.throws(() => new LibraryPreferences(state.storage).update(account, scope(), { view: 'grid' }), LibraryPreferenceError);
      assert.equal(state.values.get(key), malformed); assert.equal(state.writes(), writes);
    }
  }
});

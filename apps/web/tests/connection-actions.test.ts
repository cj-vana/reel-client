import test from 'node:test';
import assert from 'node:assert/strict';
import { hasSessionReference, removeConnectionAndRevoke, revokeUnusedSession } from '../src/connection-actions.ts';
import { Connections, type StorageLike } from '../src/storage.ts';
import { JellyfinAPI } from '../src/api.ts';
import type { Account } from '../src/types.ts';

const account = (server: string, token = 'fixture-token'): Account => ({ id: server + '|viewer', server, userId: 'viewer', token, name: 'Fixture', serverName: 'Fixture', remember: true });
function connections(accounts: Account[]) {
  const values = new Map([['reel.connections.v1', JSON.stringify({ accounts, activeId: accounts[0]?.id ?? null })]]);
  const storage: StorageLike = { getItem: key => values.get(key) ?? null, setItem: (key, value) => { values.set(key, value); }, removeItem: key => { values.delete(key); } };
  return { session: new Connections(storage), storage };
}
for (const first of [0, 1]) test('UI removal boundary preserves a retained token alias then revokes the last reference, order ' + first, async t => {
  const aliases = [account('https://fixture.example/base'), account('https://FIXTURE.example:443/base/')];
  const { session } = connections(aliases), calls: string[] = [], cleanup: string[] = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (input, init) => { const url = new URL(String(input)); assert.equal(url.pathname, '/base/Sessions/Logout'); assert.equal(init?.method, 'POST'); calls.push(new Headers(init?.headers).get('Authorization')!); return new Response(null, { status: 204 }); };
  t.after(() => { globalThis.fetch = original; session.close(); });
  const remove = (removed: Account) => removeConnectionAndRevoke({ account: removed, remove: () => session.remove(removed.id), remaining: () => session.all,
    afterRemove: async value => { cleanup.push(value.id); }, revoke: value => new JellyfinAPI(value, value.server, 'fixture', true).request<void>('Sessions/Logout', { method: 'POST' }) });
  await remove(aliases[first]); assert.equal(session.all.length, 1); assert.equal(calls.length, 0); assert.equal(cleanup.length, 1);
  assert.equal(new Connections(connectionsStorage(session.all)).all[0].token, aliases[first].token);
  await remove(aliases[1 - first]); assert.equal(calls.length, 1); assert(calls[0].includes('fixture-token')); assert.equal(session.all.length, 0);
});
function connectionsStorage(accounts: readonly Account[]): StorageLike {
  const data = JSON.stringify({ accounts, activeId: accounts[0]?.id ?? null });
  return { getItem: key => key === 'reel.connections.v1' ? data : null, setItem() {}, removeItem() {} };
}
test('a distinct removed token is revoked even when browse identity is retained', async () => {
  const removed = account('https://fixture.example/base', 'old'), retained = account('https://FIXTURE.example:443/base', 'new');
  const { session } = connections([removed, retained]), revoked: string[] = [];
  await removeConnectionAndRevoke({ account: removed, remove: () => session.remove(removed.id), remaining: () => session.all, afterRemove: async () => {}, revoke: async value => { revoked.push(value.token); } });
  assert.deepEqual(revoked, ['old']); assert.equal(session.active?.token, 'new'); session.close();
});
test('tokens on another base path or origin do not suppress revocation, while malformed matching identities fail closed', () => {
  const removed = account('https://fixture.example/base');
  assert.equal(hasSessionReference(removed, [account('https://fixture.example/other')]), false);
  assert.equal(hasSessionReference(removed, [account('https://other.example/base')]), false);
  assert.equal(hasSessionReference(removed, [account('not-a-url')]), true);
});
test('failed durable removal reaches neither preference cleanup nor Logout', async () => {
  const removed = account('https://fixture.example/base'), { session, storage } = connections([removed]);
  storage.setItem = () => { throw new Error('Denied'); }; let cleanup = 0, revocations = 0;
  await assert.rejects(removeConnectionAndRevoke({ account: removed, remove: () => session.remove(removed.id), remaining: () => session.all,
    afterRemove: async () => { cleanup++; }, revoke: async () => { revocations++; } }));
  assert.equal(session.all.length, 1); assert.equal(cleanup, 0); assert.equal(revocations, 0); session.close();
});
test('reauthentication during async local cleanup and stale-auth cleanup preserve an exact retained token', async () => {
  const removed = account('https://fixture.example/base'); let remaining: Account[] = [];
  const revoked: string[] = [];
  await removeConnectionAndRevoke({ account: removed, remove: () => {}, remaining: () => remaining,
    afterRemove: async () => { remaining = [account('https://FIXTURE.example:443/base/')]; }, revoke: async value => { revoked.push(value.token); } });
  await revokeUnusedSession(removed, () => remaining, async value => { revoked.push(value.token); });
  assert.deepEqual(revoked, []);
  await revokeUnusedSession({ ...removed, token: 'unused-auth-result' }, () => remaining, async value => { revoked.push(value.token); });
  assert.deepEqual(revoked, ['unused-auth-result']);
});

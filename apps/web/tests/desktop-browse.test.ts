import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { DesktopBrowsePreferences, type BrowseActivation } from '../src/desktop-browse.ts';
import { defaultLibraryChoices, type LibraryScope } from '../src/library-query.ts';
import type { BrowseAccount, BrowseCleanupNotice, BrowseDocument, BrowseOpenResult, BrowseWriteResult, ReelBrowsePreferences } from '../src/browse-bridge.ts';
const clone = <T>(value: T): T => JSON.parse(JSON.stringify(value)) as T;
const account = (userId = 'a', server = 'https://media.example.test/base'): BrowseAccount => ({ server, userId });
const scope = (extra: Partial<LibraryScope> = {}): LibraryScope => ({ kind: 'library', category: 'All', libraryId: '', parentId: '', parentType: '', ...extra });
const identity = (a: BrowseAccount) => JSON.stringify([a.server, a.userId]);
const doc = (a: BrowseAccount): BrowseDocument => ({ schema: 1, account: clone(a), entries: [] });
function deferred<T>() { let resolve!: (value: T) => void, reject!: (error: unknown) => void; const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; }); return { resolve, reject, promise }; }
const tick = () => new Promise<void>(resolve => setImmediate(resolve));
class Host implements ReelBrowsePreferences {
  generation = 0; count = 0; current?: { lease: string; account: BrowseAccount; generation: number };
  docs = new Map<string, BrowseDocument>(); retained = new Map<string, 'device'|'session'>();
  opens: unknown[] = []; commits: Array<Parameters<ReelBrowsePreferences['commit']>[0]> = []; resets: unknown[] = []; revokes: unknown[] = [];
  commitGate?: ReturnType<typeof deferred<void>>; resetGate?: ReturnType<typeof deferred<void>>; resetResponseGate?: ReturnType<typeof deferred<void>>; resetLostAck = false; resetRejectBefore = false; commitFail?: 'io'|'conflict'; lostAck = false;
  openFail?: BrowseOpenResult; openFailureForUser?: { user: string; code: 'io'|'unavailable'|'preserved' }; rejectTransportOnce = false; notice?: (value: BrowseCleanupNotice) => void; disposed = 0;
  revision(a: BrowseAccount) { const d = this.docs.get(identity(a)); return d ? 'sha256:' + createHash('sha256').update(JSON.stringify(d)).digest('hex') : 'absent'; }
  async open(value: { account: BrowseAccount; generation: number }): Promise<BrowseOpenResult> {
    this.opens.push(clone(value)); if (value.generation <= this.generation) return { ok: false, code: 'stale', canReset: false, notices: [] };
    this.generation = value.generation; const lease = 'lease-' + ++this.count; this.current = { lease, account: clone(value.account), generation: value.generation };
    if (this.openFailureForUser?.user === value.account.userId) return { ok: false, code: this.openFailureForUser.code, canReset: false, notices: [] };
    if (this.openFail) return { ...clone(this.openFail), ...('lease' in this.openFail ? { lease } : {}) };
    return { ok: true, lease, retention: this.retained.get(identity(value.account)) ?? 'device', revision: this.revision(value.account), document: clone(this.docs.get(identity(value.account)) ?? doc(value.account)), notices: [] };
  }
  async commit(value: Parameters<ReelBrowsePreferences['commit']>[0]): Promise<BrowseWriteResult> {
    this.commits.push(clone(value)); const active = this.current, rejectTransport = this.rejectTransportOnce; this.rejectTransportOnce = false;
    if (this.commitGate) await this.commitGate.promise;
    if (rejectTransport) throw new Error('Old transport rejected');
    if (!active || active !== this.current || value.lease !== active.lease) return { ok: false, code: 'stale' };
    if (this.commitFail) { const code = this.commitFail; this.commitFail = undefined; return { ok: false, code }; }
    if (value.expectedRevision !== this.revision(active.account)) return { ok: false, code: 'conflict' };
    assert.deepEqual(value.document.account, active.account); this.docs.set(identity(active.account), clone(value.document));
    if (this.lostAck) { this.lostAck = false; throw new Error('Transport lost after commit'); }
    return { ok: true, revision: this.revision(active.account) };
  }
  async reset(value: Parameters<ReelBrowsePreferences['reset']>[0]): Promise<BrowseWriteResult> {
    this.resets.push(clone(value)); const active = this.current;
    if (this.resetRejectBefore) { this.resetRejectBefore = false; throw new Error('Reset transport failed before commit'); }
    if (this.resetGate) await this.resetGate.promise;
    if (!active || active !== this.current || value.lease !== active.lease) return { ok: false, code: 'stale' };
    if (value.expectedRevision !== this.revision(active.account)) return { ok: false, code: 'conflict' };
    this.docs.delete(identity(active.account)); this.current = undefined; if (this.resetLostAck) { this.resetLostAck = false; throw new Error('Reset acknowledgement lost after commit'); } if (this.resetResponseGate) await this.resetResponseGate.promise; return { ok: true, revision: 'absent' };
  }
  async revoke(value: { generation: number }) { this.revokes.push(clone(value)); if (value.generation <= this.generation) return { ok: false as const, code: 'stale' as const }; this.generation = value.generation; this.current = undefined; return { ok: true as const }; }
  onCleanupNotice(callback: (value: BrowseCleanupNotice) => void) { this.notice = callback; return () => { this.disposed++; this.notice = undefined; }; }
}
function setup(host = new Host(), timeout = 1000) { let active: BrowseActivation | undefined = { account: account(), owner: 'a|1' }; const adapter = new DesktopBrowsePreferences(host, () => active, timeout); return { host, adapter, switch: (value: BrowseActivation | undefined) => { active = value; }, current: () => active }; }

test('adapter acknowledges a retained field patch only after the matching async commit succeeds', async () => {
  const { host, adapter } = setup(); await adapter.activate(); host.commitGate = deferred<void>();
  let completed = false; const work = adapter.update(account(), scope(), { view: 'list' }).then(() => { completed = true; }); await tick();
  assert.equal(completed, false); assert.equal(host.docs.size, 0); assert.equal(host.commits.length, 1);
  host.commitGate.resolve(); await work; const snapshot = await adapter.load(account(), scope()); assert.equal(snapshot.error, undefined); assert.equal(snapshot.retention, 'device'); assert.equal(snapshot.choices.view, 'list'); await adapter.close();
});
test('failed commit preserves pending choices and explicit Retry commits them against a fresh read', async () => {
  const { host, adapter } = setup(); await adapter.activate(); host.commitFail = 'io'; await assert.rejects(adapter.update(account(), scope(), { view: 'list' }));
  const failed = await adapter.load(account(), scope()); assert.equal(failed.choices.view, 'list'); assert.match(failed.error!.message, /could not be saved/); assert.equal(host.docs.size, 0);
  const recovered = await adapter.retry(account(), scope()); assert.equal(recovered.error, undefined); assert.equal(recovered.choices.view, 'list'); assert.equal(host.commits.length, 2); assert.equal(host.opens.length, 2); await adapter.close();
});
test('conflict Retry merges only edited fields into the current authoritative document', async () => {
  const { host, adapter } = setup(); await adapter.activate(); host.commitFail = 'conflict'; await assert.rejects(adapter.update(account(), scope(), { view: 'list' }));
  host.docs.set(identity(account()), { ...doc(account()), entries: [{ scope: scope(), choices: { ...defaultLibraryChoices(), watchStatus: 'Watched', sort: 'DateCreated', direction: 'Descending' } }] });
  const result = await adapter.retry(account(), scope()); assert.equal(result.choices.view, 'list'); assert.equal(result.choices.watchStatus, 'Watched'); assert.equal(result.choices.sort, 'DateCreated'); assert.equal(result.error, undefined); await adapter.close();
});
test('lost acknowledgement is uncertain and Retry does not automatically reissue an already accepted write', async () => {
  const { host, adapter } = setup(); await adapter.activate(); host.lostAck = true; await assert.rejects(adapter.update(account(), scope(), { view: 'list' }), /could not confirm/);
  assert.equal(host.docs.get(identity(account()))!.entries[0].choices.view, 'list'); const count = host.commits.length, opens = host.opens.length;
  const result = await adapter.retry(account(), scope()); assert.match(result.error!.message, /Quit and reopen/); assert.equal(result.canReset, false); assert.equal(host.commits.length, count); assert.equal(host.opens.length, opens); await adapter.close();
});
test('bounded write timeout retains uncertainty after a late response rather than publishing Saved', async () => {
  const { host, adapter } = setup(new Host(), 5); await adapter.activate(); host.commitGate = deferred<void>();
  await assert.rejects(adapter.update(account(), scope(), { genreId: 'drama' }), /could not confirm/); host.commitGate.resolve(); await tick();
  const snapshot = await adapter.load(account(), scope()); assert.match(snapshot.error!.message, /could not confirm/); assert.equal(snapshot.choices.genreId, 'drama'); assert.equal(snapshot.canReset, false); await adapter.close();
});
test('concurrent edits retain field versions across the first acknowledgement', async () => {
  const { host, adapter } = setup(); await adapter.activate(); host.commitGate = deferred<void>();
  const first = adapter.update(account(), scope(), { view: 'list' }); await tick(); const second = adapter.update(account(), scope(), { direction: 'Descending' });
  host.commitGate.resolve(); await Promise.all([first, second]); const result = await adapter.load(account(), scope()); assert.equal(result.choices.view, 'list'); assert.equal(result.choices.direction, 'Descending'); assert.equal(host.commits.length, 2);
  assert.equal(host.commits[0].document.entries[0].choices.direction, 'Ascending'); assert.equal(host.commits[1].document.entries[0].choices.direction, 'Descending'); await adapter.close();
});
test('same account across base paths and another account keep distinct document identities', async () => {
  const state = setup(); await state.adapter.activate(); await state.adapter.update(account(), scope(), { view: 'list' });
  const second = account('a', 'https://media.example.test/second'); state.switch({ account: second, owner: 'a-second|2' }); await state.adapter.activate(); await state.adapter.update(second, scope(), { sort: 'DateCreated' });
  state.switch({ account: account('b'), owner: 'b|3' }); await state.adapter.activate(); assert.equal((await state.adapter.load(account('b'), scope())).choices.view, 'grid');
  assert.equal(state.host.docs.size, 2); assert.equal(state.host.docs.get(identity(account()))!.entries[0].choices.view, 'list'); await state.adapter.close();
});
test('session-only retention stays explicit and does not claim file durability', async () => {
  const host = new Host(); host.retained.set(identity(account()), 'session'); const { adapter } = setup(host); await adapter.activate(); await adapter.update(account(), scope(), { view: 'list' });
  assert.equal((await adapter.load(account(), scope())).retention, 'session'); await adapter.close();
});
test('account activation on Home revokes the old context before its held commit can publish', async () => {
  const state = setup(); await state.adapter.activate(); state.host.commitGate = deferred<void>();
  const work = state.adapter.update(account(), scope(), { view: 'list' }); await tick();
  state.switch({ account: account('b'), owner: 'b|2' }); await state.adapter.activate(); state.host.commitGate.resolve(); await assert.rejects(work);
  assert.equal(state.host.docs.size, 0); const b = await state.adapter.load(account('b'), scope()); assert.equal(b.choices.view, 'grid'); assert.equal(b.error, undefined); await state.adapter.close();
});
test('no active account advances revoke generation and rejects old queued writes', async () => {
  const state = setup(); await state.adapter.activate(); state.switch(undefined); await state.adapter.activate(); assert.equal(state.host.current, undefined); assert.equal(state.host.revokes.length, 1);
  await assert.rejects(state.adapter.update(account(), scope(), { view: 'list' }), /active connection changed/); assert.equal(state.host.commits.length, 0); await state.adapter.close();
});
test('own reset-capable corrupt data needs confirmed Reset and fresh lease before the next commit', async () => {
  const host = new Host(); host.openFail = { ok: false, code: 'corrupt', lease: 'replaced', retention: 'device', revision: 'absent', canReset: true, notices: [] };
  const { adapter } = setup(host); await adapter.activate(); const bad = await adapter.load(account(), scope()); assert.equal(bad.canReset, true);
  await assert.rejects(adapter.update(account(), scope(), { view: 'list' })); assert.equal(host.commits.length, 0); host.openFail = undefined;
  const oldLease = host.current!.lease; await adapter.reset(account()); assert.notEqual(host.current!.lease, oldLease); assert.equal(host.opens.length, 2);
  await adapter.update(account(), scope(), { sort: 'DateCreated' }); const saved = await adapter.load(account(), scope()); assert.equal(saved.choices.view, 'grid'); assert.equal(saved.choices.sort, 'DateCreated'); await adapter.close();
});
test('foreign or unreadable ownership has no reset authority and preserves the host data', async () => {
  const host = new Host(); host.openFail = { ok: false, code: 'preserved', canReset: false, notices: [] }; const { adapter } = setup(host); await adapter.activate();
  assert.equal((await adapter.load(account(), scope())).canReset, false); await assert.rejects(adapter.reset(account()), /left untouched/); assert.equal(host.resets.length, 0); await adapter.close();
});
test('host-returned foreign embedded account is rejected before any commit', async () => {
  const host = new Host(); host.docs.set(identity(account()), doc(account('foreign'))); const { adapter } = setup(host); await adapter.activate();
  const snapshot = await adapter.load(account(), scope()); assert.equal(snapshot.canReset, false); assert.match(snapshot.error!.message, /left untouched/); await assert.rejects(adapter.update(account(), scope(), { view: 'list' })); assert.equal(host.commits.length, 0); await adapter.close();
});
test('committed inactive session-only removal clears only that session and restores the still-current account', async () => {
  const state = setup(), a = account(), b = account('b'); state.host.retained.set(identity(a), 'session');
  await state.adapter.activate(); await state.adapter.update(a, scope(), { view: 'list' }); state.switch({ account: b, owner: 'b|2' }); await state.adapter.activate(); await state.adapter.update(b, scope(), { direction: 'Descending' });
  await state.adapter.removeAccount(a); assert.equal(state.host.docs.has(identity(a)), false); assert.equal(state.host.current!.account.userId, 'b'); assert.equal((await state.adapter.load(b, scope())).choices.direction, 'Descending');
  state.switch({ account: a, owner: 'a-readded|3' }); await state.adapter.activate(); assert.equal((await state.adapter.load(a, scope())).choices.view, 'grid'); await state.adapter.close();
});
test('renderer removal never resets a device-retention document owned by the host cleanup hook', async () => {
  const state = setup(); await state.adapter.activate(); await state.adapter.update(account(), scope(), { view: 'list' });
  await state.adapter.removeAccount(account()); assert.equal(state.host.resets.length, 0); assert.equal(state.host.docs.size, 1); await state.adapter.close();
});
test('sanitized cleanup notices replay once per ID, reject raw identities and stop after disposal', async () => {
  const { host, adapter } = setup(); const received: number[] = []; adapter.setNoticeHandler(notices => received.push(notices.length));
  const notice: BrowseCleanupNotice = { id: 'notice-1', accountId: 'a'.repeat(64), count: 1, code: 'preserved' };
  host.notice!(notice); host.notice!(notice); host.notice!({ ...notice, id: 'invalid', accountId: 'https://private.example/user' }); assert.equal(received.at(-1), 1);
  await adapter.close(); assert.equal(host.disposed, 1); assert.equal(host.notice, undefined);
});
test('missing new host bridge shows unavailable rather than silently persisting into localStorage', async () => {
  const adapter = new DesktopBrowsePreferences(undefined, () => ({ account: account(), owner: '1' })); await adapter.activate(); const snapshot = await adapter.load(account(), scope()); assert.match(snapshot.error!.message, /unavailable/); assert.equal(snapshot.canReset, false); await adapter.close();
});

test('Reset consumes the old lease and old-generation queued edits require an explicit Retry', async () => {
  const { host, adapter } = setup(); host.openFail = { ok: false, code: 'corrupt', lease: 'replaced', retention: 'device', revision: 'absent', canReset: true, notices: [] }; await adapter.activate(); await assert.rejects(adapter.update(account(), scope(), { view: 'list' })); host.openFail = undefined;
  const oldLease = host.current!.lease; host.resetGate = deferred<void>(); const reset = adapter.reset(account()); await tick();
  const later = adapter.update(account(), scope(), { sort: 'ProductionYear' }); const finished = Promise.allSettled([reset, later]); host.resetGate.resolve(); const outcomes = await finished; assert.equal(outcomes[0].status, 'fulfilled'); assert.equal(outcomes[1].status, 'rejected');
  const snapshot = await adapter.load(account(), scope()); assert.equal(snapshot.choices.view, 'grid'); assert.equal(snapshot.choices.sort, 'SortName'); assert.equal(snapshot.error, undefined); assert.equal(snapshot.previousPending, true);
  const retried = await adapter.retry(account(), scope()); assert.equal(retried.choices.sort, 'ProductionYear'); assert.notEqual(host.commits.at(-1)!.lease, oldLease); assert.equal(host.commits.at(-1)!.expectedRevision, 'absent'); await adapter.close();
});
test('malformed enum patch never becomes a pending saved value or reaches host commit', async () => {
  const { host, adapter } = setup(); await adapter.activate();
  await assert.rejects(adapter.update(account(), scope(), { watchStatus: ['Watched'] as never }), /invalid/); assert.equal(host.commits.length, 0); assert.equal((await adapter.load(account(), scope())).choices.watchStatus, 'Any'); await adapter.close();
});

test('close is idempotent and disposes its one subscription and generation revoke exactly once', async () => {
  const { host, adapter } = setup(); await adapter.activate(); const first = adapter.close(), second = adapter.close(); assert.equal(first, second); await Promise.all([first, second]); assert.equal(host.disposed, 1); assert.equal(host.revokes.length, 1);
});

test('client lost acknowledgement stays quarantined across account switches and cannot reopen or write A', async () => {
  const state = setup(); await state.adapter.activate(); state.host.lostAck = true; await assert.rejects(state.adapter.update(account(), scope(), { view: 'list' }));
  state.switch({ account: account('b'), owner: 'b|2' }); await state.adapter.activate(); await state.adapter.update(account('b'), scope(), { direction: 'Descending' });
  const aOpens = state.host.opens.filter((value: any) => value.account.userId === 'a').length, aCommits = state.host.commits.filter(value => value.document.account.userId === 'a').length;
  state.switch({ account: account(), owner: 'a|3' }); await state.adapter.activate(); const quarantined = await state.adapter.retry(account(), scope()); assert.match(quarantined.error!.message, /Quit and reopen/); assert.equal(quarantined.canRetry, false); assert.equal(quarantined.canReset, false);
  await assert.rejects(state.adapter.update(account(), scope(), { direction: 'Descending' }));
  assert.equal(state.host.opens.filter((value: any) => value.account.userId === 'a').length, aOpens); assert.equal(state.host.commits.filter(value => value.document.account.userId === 'a').length, aCommits); await state.adapter.close();
});
test('timed-out uncommitted write remains quarantined after switching away/back and a late response', async () => {
  const state = setup(new Host(), 5); await state.adapter.activate(); state.host.commitGate = deferred<void>();
  await assert.rejects(state.adapter.update(account(), scope(), { view: 'list' })); state.switch({ account: account('b'), owner: 'b|2' }); await state.adapter.activate();
  const opened = state.host.opens.length; state.switch({ account: account(), owner: 'a|3' }); await state.adapter.activate(); state.host.commitGate.resolve(); await tick();
  const result = await state.adapter.retry(account(), scope()); assert.match(result.error!.message, /could not confirm/); assert.equal(state.host.opens.length, opened); assert.equal(state.host.docs.has(identity(account())), false); await state.adapter.close();
});
test('same normalized account new-owner activation is not poisoned by old typed or transport failure', async () => {
  for (const transport of [false, true]) {
    const state = setup(); await state.adapter.activate(); state.host.commitGate = deferred<void>(); state.host.rejectTransportOnce = transport;
    const old = state.adapter.update(account(), scope(), { view: 'list' }); const oldOutcome = old.catch(error => error); await tick();
    state.switch({ account: account(), owner: 'a-refreshed-token|2' }); await state.adapter.activate(); state.host.commitGate.resolve(); await oldOutcome;
    const fresh = await state.adapter.load(account(), scope()); assert.equal(fresh.error, undefined); assert.equal(fresh.choices.view, 'grid'); assert.equal(fresh.previousPending, true);
    await state.adapter.update(account(), scope(), { sort: 'DateCreated' }); const saved = await state.adapter.load(account(), scope()); assert.equal(saved.error, undefined); assert.equal(saved.choices.sort, 'DateCreated'); assert.equal(saved.choices.view, 'grid');
    assert.equal(state.host.commits.at(-1)!.document.entries[0].choices.view, 'grid'); await state.adapter.close();
  }
});
test('queued old-owner edit reset and Retry cannot send through a refreshed lease', async () => {
  const state = setup(); await state.adapter.activate(); state.host.commitGate = deferred<void>();
  const old = state.adapter.update(account(), scope(), { view: 'list' }); await tick();
  const edit = state.adapter.update(account(), scope(), { direction: 'Descending' }), reset = state.adapter.reset(account()), retry = state.adapter.retry(account(), scope());
  const outcomes = Promise.allSettled([old, edit, reset, retry]); state.switch({ account: account(), owner: 'same-account-new-owner|2' }); await state.adapter.activate(); const opens = state.host.opens.length;
  state.host.commitGate.resolve(); const results = await outcomes; assert(results.every(result => result.status === 'rejected')); assert.equal(state.host.commits.length, 1); assert.equal(state.host.resets.length, 0); assert.equal(state.host.opens.length, opens);
  const snapshot = await state.adapter.load(account(), scope()); assert.equal(snapshot.error, undefined); assert.equal(snapshot.choices.direction, 'Ascending'); await state.adapter.close();
});
test('typed failed session removal warns nonfatally preserves A and restores current B', async () => {
  for (const code of ['io', 'unavailable', 'preserved'] as const) {
    const state = setup(); state.host.retained.set(identity(account()), 'session'); await state.adapter.activate(); await state.adapter.update(account(), scope(), { view: 'list' });
    state.switch({ account: account('b'), owner: 'b|2' }); await state.adapter.activate(); await state.adapter.update(account('b'), scope(), { sort: 'DateCreated' });
    const notices: BrowseCleanupNotice[][] = []; state.adapter.setNoticeHandler(values => notices.push([...values])); state.host.openFailureForUser = { user: 'a', code };
    await assert.rejects(state.adapter.removeAccount(account())); assert.equal(state.host.resets.length, 0); assert.equal(state.host.docs.get(identity(account()))!.entries[0].choices.view, 'list'); assert.equal(state.host.current!.account.userId, 'b');
    assert.equal((await state.adapter.load(account('b'), scope())).choices.sort, 'DateCreated'); assert.equal(notices.at(-1)!.length, 1); assert.equal(notices.at(-1)![0].code, code === 'preserved' ? 'preserved' : 'io'); await state.adapter.close();
  }
});

test('uncertain Reset with no pending edits survives more than32 account activations until a new renderer', async () => {
  for (const mode of ['lost-committed', 'uncommitted-rejection', 'timed-out-late-ack'] as const) {
    const host = new Host(), state = setup(host, mode === 'timed-out-late-ack' ? 5 : 1000), a = account();
    host.docs.set(identity(a), { ...doc(a), entries: [{ scope: scope(), choices: { ...defaultLibraryChoices(), view: 'list' } }] });
    host.openFail = { ok: false, code: 'corrupt', retention: 'device', lease: 'reset-lease', revision: host.revision(a), canReset: true, notices: [] };
    await state.adapter.activate(); assert.equal((await state.adapter.load(a, scope())).canReset, true);
    if (mode === 'lost-committed') host.resetLostAck = true;
    if (mode === 'uncommitted-rejection') host.resetRejectBefore = true;
    if (mode === 'timed-out-late-ack') host.resetResponseGate = deferred<void>();
    await assert.rejects(state.adapter.reset(a), /could not confirm/); host.openFail = undefined;
    assert.equal(host.docs.has(identity(a)), mode === 'uncommitted-rejection');
    const original = await state.adapter.load(a, scope()); assert.equal(original.previousPending, false); assert.equal(original.canRetry, false); assert.equal(original.canReset, false);
    const firstOpens = host.opens.filter(value => (value as { account: BrowseAccount }).account.userId === 'a').length;
    for (let i = 0; i < 40; i++) { const b = account('capacity-' + i); state.switch({ account: b, owner: b.userId + '|1' }); await state.adapter.activate(); assert.equal((await state.adapter.load(b, scope())).error, undefined); }
    const b = state.current()!.account; await state.adapter.update(b, scope(), { view: 'list' }); assert.equal((await state.adapter.load(b, scope())).choices.view, 'list');
    if (host.resetResponseGate) { host.resetResponseGate.resolve(); await tick(); }
    state.switch({ account: a, owner: 'a|returned' }); await state.adapter.activate(); const back = await state.adapter.load(a, scope());
    assert(back.error, 'Uncertain Reset quarantine must survive capacity pressure'); assert.match(back.error.message, /Quit and reopen/); assert.equal(back.canRetry, false); assert.equal(back.canReset, false);
    const commits = host.commits.length, resets = host.resets.length; await state.adapter.retry(a, scope()); await assert.rejects(state.adapter.update(a, scope(), { sort: 'DateCreated' }), /Quit and reopen/); await assert.rejects(state.adapter.reset(a), /Quit and reopen/);
    assert.equal(host.opens.filter(value => (value as { account: BrowseAccount }).account.userId === 'a').length, firstOpens); assert.equal(host.commits.length, commits); assert.equal(host.resets.length, resets);
    await state.adapter.close();
    host.generation = 0; host.current = undefined; const fresh = setup(host); await fresh.adapter.activate(); assert.equal((await fresh.adapter.load(a, scope())).error, undefined); await fresh.adapter.close();
  }
});
test('a cache filled only by uncertain Reset states refuses capacity without evicting quarantine', async () => {
  const host = new Host(), state = setup(host);
  for (let i = 0; i < 32; i++) {
    const a = account('quarantined-' + i); state.switch({ account: a, owner: a.userId + '|1' }); host.openFail = { ok: false, code: 'corrupt', retention: 'device', lease: 'reset-lease', revision: 'absent', canReset: true, notices: [] };
    await state.adapter.activate(); host.resetLostAck = true; await assert.rejects(state.adapter.reset(a), /could not confirm/);
  }
  host.openFail = undefined; const before = host.opens.length; state.switch({ account: account('over-capacity'), owner: 'over-capacity|1' }); await assert.rejects(state.adapter.activate(), /limit/i); assert.equal(host.opens.length, before);
  state.switch({ account: account('quarantined-0'), owner: 'quarantined-0|returned' }); await state.adapter.activate(); const snapshot = await state.adapter.load(account('quarantined-0'), scope()); assert.match(snapshot.error!.message, /Quit and reopen/); assert.equal(snapshot.canRetry, false); assert.equal(snapshot.canReset, false); assert.equal(host.opens.length, before); assert.equal(host.commits.length, 0); await state.adapter.close();
});

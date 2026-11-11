import test from 'node:test';
import assert from 'node:assert/strict';
import { addressRoute, routeAddress, ScreenHistory } from '../src/web-history.ts';

const ID = '0123456789abcdef0123456789abcdef';

test('every screen with an address reads back as the same screen', () => {
  for (const name of ['Home', 'Library', 'Favorites', 'Search', 'Music', 'Photos', 'Books', 'Live TV', 'Devices', 'Settings', 'Connections']) {
    assert.deepEqual(addressRoute(routeAddress({ name })), { name }, name);
  }
  assert.equal(routeAddress({ name: 'Home' }), '#/');
  assert.equal(routeAddress({ name: 'Live TV' }), '#/live-tv');
  assert.equal(routeAddress({ name: 'Details', item: ID }), '#/title/' + ID);
  assert.deepEqual(addressRoute('#/title/' + ID), { name: 'Details', item: ID });
  assert.deepEqual(addressRoute(''), { name: 'Home' }, 'the bare page is Home');
  assert.deepEqual(addressRoute('#'), { name: 'Home' });
});

test('an address carries a screen and one title id, never search text, filters, folders or an account', () => {
  const route = { name: 'Search', query: 'a private search', filter: 'Movies', library: 'lib', sort: 'Name', scrollY: 400 };
  assert.equal(routeAddress(route), '#/search');
  assert.equal(routeAddress({ name: 'Library', parent: ID, parentType: 'BoxSet' } as { name: string }), '#/library');
  assert.equal(routeAddress({ name: 'Downloads' }), '#/', 'a screen without an address reads as Home');
  assert.equal(routeAddress({ name: 'Details' }), '#/');
  assert.equal(routeAddress({ name: 'Details', item: 'a/b' }), '#/');
});

test('addresses that are not Reel screens are refused', () => {
  for (const hash of ['#library', '#/nowhere', '#/title', '#/title/', '#/title/a/b', '#/title/' + 'a'.repeat(65), '#/title/<script>', '#/title/a%2Fb', '#/library/folder/' + ID,
    '#/settings/extra', '#/title/' + ID + '?play=1', '#//', '#/Home', '#/' + 'a'.repeat(200)]) {
    assert.equal(addressRoute(hash), undefined, hash);
  }
});

/** A stand-in for the browser: a list of entries, each with its state and address, and a current position. */
function browserHistory() {
  const entries: { state: unknown; url: string }[] = [{ state: null, url: '' }];
  let index = 0;
  const moves: number[] = [];
  const hash = () => entries[index].url.startsWith('#') ? entries[index].url : '';
  return {
    entries, moves, get index() { return index; }, get state() { return entries[index].state; }, hash,
    pushState(state: unknown, _unused: string, url: string) { entries.splice(index + 1); entries.push({ state, url }); index++; },
    replaceState(state: unknown, _unused: string, url: string) { entries[index] = { state, url }; },
    go(delta: number) { moves.push(delta); index = Math.max(0, Math.min(entries.length - 1, index + delta)); },
    /** The browser's own button: move, then tell the page. */
    press(delta: number) { index = Math.max(0, Math.min(entries.length - 1, index + delta)); return [entries[index].state, hash()] as const; },
    /** An address typed into the bar: a new entry with no state. */
    type(url: string) { entries.splice(index + 1); entries.push({ state: null, url }); index++; return [null, url] as const; }
  };
}
const visit = (browser: ReturnType<typeof browserHistory>) => new ScreenHistory(browser, () => '/app/');

test('a new screen adds a browser entry, and Back and Forward say what to show', () => {
  const browser = browserHistory(), screens = visit(browser);
  screens.show({ name: 'Home' }, false);
  assert.equal(screens.canGoBack, false);
  screens.show({ name: 'Library' }, true); screens.show({ name: 'Details', item: ID }, true);
  assert.deepEqual(browser.entries, [{ state: { reel: 0 }, url: '/app/' }, { state: { reel: 1 }, url: '#/library' }, { state: { reel: 2 }, url: '#/title/' + ID }]);
  assert.equal(screens.canGoBack, true);
  assert.deepEqual(screens.moved(...browser.press(-1)), { kind: 'back', steps: 1, address: '#/library', route: { name: 'Library' } });
  screens.show({ name: 'Library' }, false);
  assert.deepEqual(browser.entries[1], { state: { reel: 1 }, url: '#/library' }, 'the entry gone back to keeps its place');
  assert.deepEqual(screens.moved(...browser.press(1)), { kind: 'open', route: { name: 'Details', item: ID } });
  // Showing a screen after a move corrects the entry landed on, even when the app would have added one.
  screens.show({ name: 'Details', item: ID }, true);
  assert.equal(browser.entries.length, 3); assert.deepEqual(browser.entries[2].state, { reel: 2 });
  assert.deepEqual(screens.moved(...browser.press(-2)), { kind: 'back', steps: 2, address: '#/', route: { name: 'Home' } });
});

test('after a reload the entries of the same visit are still told apart as Back and Forward', () => {
  const browser = browserHistory(), first = visit(browser);
  first.show({ name: 'Home' }, false); first.show({ name: 'Library' }, true); first.show({ name: 'Details', item: ID }, true);
  // The page loads again on the title: nothing is in memory, but the browser kept each entry's place.
  const reloaded = visit(browser);
  reloaded.show({ name: 'Details', item: ID }, false);
  assert.deepEqual(browser.entries[2].state, { reel: 2 }, 'the reloaded entry keeps its place');
  assert.equal(reloaded.canGoBack, true);
  assert.deepEqual(reloaded.moved(...browser.press(-1)), { kind: 'back', steps: 1, address: '#/library', route: { name: 'Library' } });
  reloaded.show({ name: 'Library' }, false);
  assert.deepEqual(reloaded.moved(...browser.press(-1)), { kind: 'back', steps: 1, address: '#/', route: { name: 'Home' } });
  reloaded.show({ name: 'Home' }, false);
  assert.equal(reloaded.canGoBack, false);
  assert.deepEqual(reloaded.moved(...browser.press(2)), { kind: 'open', route: { name: 'Details', item: ID } });
});

test('the page Back button uses the browser entry', () => {
  const browser = browserHistory(), screens = visit(browser);
  screens.show({ name: 'Home' }, false); screens.show({ name: 'Search' }, true);
  screens.goBack();
  assert.deepEqual(browser.moves, [-1]);
  assert.deepEqual(screens.moved(browser.state, browser.hash()), { kind: 'back', steps: 1, address: '#/', route: { name: 'Home' } });
});

test('a move made while a sheet or the player is open is undone without showing anything', () => {
  const browser = browserHistory(), screens = visit(browser);
  screens.show({ name: 'Home' }, false); screens.show({ name: 'Details', item: ID }, true);
  assert.equal(screens.moved(...browser.press(-1))?.kind, 'back');
  screens.undo();
  assert.deepEqual(browser.moves, [1]); assert.equal(browser.index, 1);
  assert.equal(screens.moved(browser.state, browser.hash()), undefined, 'the return trip is not a move to act on');
  assert.equal(screens.canGoBack, true);
  screens.undo(); assert.deepEqual(browser.moves, [1], 'nothing more to undo');
  // The next screen is still added after the title, at the right place.
  screens.show({ name: 'Settings' }, true);
  assert.deepEqual(browser.entries[2], { state: { reel: 2 }, url: '#/settings' });
  // Forward is undone the other way.
  screens.moved(...browser.press(-1)); screens.show({ name: 'Details', item: ID }, false);
  assert.equal(screens.moved(...browser.press(1))?.kind, 'open');
  screens.undo();
  assert.deepEqual(browser.moves, [1, -1]);
});

test('a typed address opens its screen as the next entry and an unknown one opens nothing', () => {
  const browser = browserHistory(), screens = visit(browser);
  screens.show({ name: 'Home' }, false);
  assert.deepEqual(screens.moved(...browser.type('#/settings')), { kind: 'open', route: { name: 'Settings' } });
  screens.show({ name: 'Settings' }, true);
  assert.deepEqual(browser.entries, [{ state: { reel: 0 }, url: '/app/' }, { state: { reel: 1 }, url: '#/settings' }]);
  assert.deepEqual(screens.moved(...browser.type('#/title/<img>')), { kind: 'open', route: undefined });
  // Nothing opens: the bar is put back to the screen that is showing.
  screens.show({ name: 'Settings' }, false);
  assert.deepEqual(browser.entries[2], { state: { reel: 2 }, url: '#/settings' });
  assert.deepEqual(screens.moved(...browser.type('#/favorites')), { kind: 'open', route: { name: 'Favorites' } });
  screens.undo();
  assert.deepEqual(browser.moves, [-1], 'a typed address made a new entry, so undoing it goes back one');
  assert.deepEqual(screens.moved({ reel: 'x' }, '#/favorites'), undefined, 'and that return trip is ignored');
});

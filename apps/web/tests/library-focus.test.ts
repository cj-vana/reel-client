import test from 'node:test';
import assert from 'node:assert/strict';
import { mediaFocusIdentity } from '../src/library-focus.ts';
const item = (Id: string, PlaylistItemId?: string) => ({ Id, Name: Id, PlaylistItemId });
test('retained media identity follows a reordered item rather than its previous index', () => {
  const before = [item('a'), item('b'), item('c')], after = [item('c'), item('a'), item('b')];
  assert.equal(mediaFocusIdentity(before, 1, false), mediaFocusIdentity(after, 2, false));
  assert.notEqual(mediaFocusIdentity(before, 1, false), mediaFocusIdentity(after, 1, false));
});
test('playlist entry identities distinguish repeated media, surviving a reorder of entries', () => {
  const before = [item('same', 'first'), item('same', 'second')], after = [...before].reverse();
  assert.notEqual(mediaFocusIdentity(before, 0, true), mediaFocusIdentity(before, 1, true));
  assert.equal(mediaFocusIdentity(before, 1, true), mediaFocusIdentity(after, 0, true));
});
test('legacy playlist occurrence keys preserve duplicate ordinal and do not collide across media IDs', () => {
  const sequence = [item('a'), item('b'), item('a')];
  assert.equal(mediaFocusIdentity(sequence, 2, true), 'occurrence:a:1'); assert.equal(new Set(sequence.map((_item, index) => mediaFocusIdentity(sequence, index, true))).size, 3);
});

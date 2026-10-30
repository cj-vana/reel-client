import test from 'node:test';
import assert from 'node:assert/strict';
import { fixtureAddedDate, sortFixtureItems } from '../scripts/fixture-library.mjs';

const ids = (items: Array<{ Id: string }>) => items.map(item => item.Id);
const items = [
  { Id: 'old', Name: 'Zebra', DateCreated: fixtureAddedDate(1), ProductionYear: 2001 },
  { Id: 'new-z', Name: 'Zebra', DateCreated: fixtureAddedDate(75), ProductionYear: 2025 },
  { Id: 'new-a', Name: 'Alpha', DateCreated: fixtureAddedDate(75), ProductionYear: 2025 }
];
test('fixture date vectors honor newest first and ascending title ties without mutating the catalogue', () => {
  assert.deepEqual(ids(sortFixtureItems(items, 'DateCreated,SortName', 'Descending,Ascending')), ['new-a', 'new-z', 'old']);
  assert.deepEqual(ids(items), ['old', 'new-z', 'new-a']);
  assert.ok(Date.parse(fixtureAddedDate(75)) > Date.parse(fixtureAddedDate(1)));
});
test('fixture explicit oldest first reverses the primary date but preserves the secondary title direction', () => {
  assert.deepEqual(ids(sortFixtureItems(items, 'DateCreated,SortName', 'Ascending,Ascending')), ['old', 'new-a', 'new-z']);
});
test('fixture release year and title follow independent ascending and descending vectors', () => {
  assert.deepEqual(ids(sortFixtureItems(items, 'ProductionYear,SortName', 'Descending,Ascending')), ['new-a', 'new-z', 'old']);
  assert.deepEqual(ids(sortFixtureItems(items, 'ProductionYear,SortName', 'Ascending,Descending')), ['old', 'new-z', 'new-a']);
  assert.deepEqual(ids(sortFixtureItems(items, 'SortName', 'Descending')), ['old', 'new-z', 'new-a']);
});
test('fixture unknown dates remain missing and sort after known dates in either direction', () => {
  const values = [...items, { Id: 'unknown', Name: 'Absent date' }, { Id: 'bad', Name: 'Bad date', DateCreated: 'invalid' }];
  for (const direction of ['Ascending', 'Descending']) {
    assert.deepEqual(ids(sortFixtureItems(values, 'DateCreated,SortName', direction + ',Ascending')).slice(-2), ['unknown', 'bad']);
  }
});
test('fixture series latest content dates are distinct from series creation and absent sort retains server order', () => {
  const values = [{ Id: 'a', Name: 'A', DateCreated: fixtureAddedDate(1), DateLastMediaAdded: fixtureAddedDate(75) }, { Id: 'b', Name: 'B', DateCreated: fixtureAddedDate(75), DateLastMediaAdded: fixtureAddedDate(1) }];
  assert.deepEqual(ids(sortFixtureItems(values, 'DateLastContentAdded,SortName', 'Descending,Ascending')), ['a', 'b']);
  assert.deepEqual(ids(sortFixtureItems(values, 'DateCreated,SortName', 'Descending,Ascending')), ['b', 'a']);
  assert.deepEqual(ids(sortFixtureItems(values)), ['a', 'b']);
});

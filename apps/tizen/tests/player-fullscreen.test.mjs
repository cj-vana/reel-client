import test from 'node:test';
import assert from 'node:assert/strict';
import {nativeVideoOwnsFullscreen} from '../src/adapter.mjs';

test('native video fullscreen retains native remote direction ownership',()=>{
  assert.equal(nativeVideoOwnsFullscreen({fullscreenElement:{tagName:'VIDEO'}}),true);
});
test('app player-container fullscreen continues legacy-key normalization for the complete controls',()=>{
  for(const element of [null,{tagName:'SECTION',id:'player'},{tagName:'DIV'}])assert.equal(nativeVideoOwnsFullscreen({fullscreenElement:element}),false);
});

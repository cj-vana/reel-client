import test from 'node:test';
import assert from 'node:assert/strict';
import {supportedMediaKeys,mediaAction,legacyDirection} from '../src/policy.mjs';

const native=[{name:'MediaPlayPause',code:10252},{name:'MediaPlay',code:415},{name:'MediaPause',code:19},{name:'MediaStop',code:413},{name:'MediaFastForward',code:417},{name:'MediaRewind',code:412}];

test('registration selects supported media names without mandatory/system keys',()=>{
  const keys=[...native,{name:'Back',code:10009},{name:'Exit',code:10182},{name:'VolumeUp',code:447}];
  assert.deepEqual(supportedMediaKeys(keys).map(key=>key.name),['MediaPlayPause','MediaPlay','MediaPause','MediaStop','MediaFastForward','MediaRewind']);
  assert.deepEqual(supportedMediaKeys([{name:'MediaPlay',code:415}]).map(key=>key.name),['MediaPlay']);
});
test('malformed, reserved and ambiguous native codes cannot override navigation or IME',()=>{
  assert.deepEqual(supportedMediaKeys(null),[]);
  assert.deepEqual(supportedMediaKeys([{name:'MediaPlay',code:13},{name:'MediaStop',code:65385},{name:'MediaPause',code:'19'}]),[]);
  assert.equal(supportedMediaKeys([{name:'MediaPlayPause',code:500},{name:'MediaPlay',code:500}]).length,1);
});
test('native and standard media events map to the intended distinct actions',()=>{
  for(const [keyCode,action]of[[10252,'toggle'],[415,'play'],[19,'pause'],[413,'stop'],[417,'forward'],[412,'rewind']])assert.equal(mediaAction({keyCode},new Map()),action);
  assert.equal(mediaAction({key:'MediaPlayPause'},new Map()),'toggle');
  assert.equal(mediaAction({keyCode:900},new Map([[900,'stop']])),'stop');assert.equal(mediaAction({keyCode:447},new Map()),null);
});
test('legacy arrow mapping does not steal IME, Back, Enter or forced Exit',()=>{
  assert.deepEqual([37,38,39,40].map(keyCode=>legacyDirection({keyCode})),['ArrowLeft','ArrowUp','ArrowRight','ArrowDown']);
  for(const keyCode of[13,10009,10182,229,65376,65385])assert.equal(legacyDirection({keyCode}),null);
});

export const MEDIA_KEYS = Object.freeze([
  {name:'MediaPlayPause',code:10252,action:'toggle'},
  {name:'MediaPlay',code:415,action:'play'},
  {name:'MediaPause',code:19,action:'pause'},
  {name:'MediaStop',code:413,action:'stop'},
  {name:'MediaFastForward',code:417,action:'forward'},
  {name:'MediaRewind',code:412,action:'rewind'}
]);
export const RESERVED_CODES = Object.freeze([13,37,38,39,40,10009,10182,65376,65385,229]);

export function supportedMediaKeys(keys) {
  if(!Array.isArray(keys))return [];
  const selected=[],codes=new Set();
  for(const expected of MEDIA_KEYS){
    const candidate=keys.find(key=>key&&key.name===expected.name);
    if(candidate&&Number.isInteger(candidate.code)&&candidate.code>0&&!RESERVED_CODES.includes(candidate.code)&&!codes.has(candidate.code)){selected.push({...expected,code:candidate.code});codes.add(candidate.code);}
  }
  return selected;
}

export function mediaAction(event,registered) {
  const dynamic=registered.get(event.keyCode);
  if(dynamic)return dynamic;
  const key=MEDIA_KEYS.find(key=>key.name===event.key||key.code===event.keyCode);
  return key?key.action:null;
}

export function legacyDirection(event) {
  const names={37:'ArrowLeft',38:'ArrowUp',39:'ArrowRight',40:'ArrowDown'};
  return names[event.keyCode]||null;
}

export function textEntry(element) {
  if(!element||typeof element.matches!=='function')return false;
  return element.isContentEditable||element.matches('textarea,input:not([type="checkbox"]):not([type="radio"]):not([type="button"]):not([type="submit"])');
}

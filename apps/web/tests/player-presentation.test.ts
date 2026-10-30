import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import postcss from 'postcss';
import { playbackTime, PlayerControls, installPlayerPresentation, togglePlayerFullscreen, exitPlayerFullscreen, nativeVideoFullscreen, installPageCacheRecovery, restoreAfterNavigation, scrollFormatPanel, statusContainer, playerActivationAllowed } from '../src/player-presentation.ts';
import { installNavigation, navigationVisible } from '../src/navigation.ts';

function clock() {
  let next = 0; const pending = new Map<number, () => void>();
  return { pending, set(callback: () => void, milliseconds: number) { assert.equal(milliseconds, 3000); pending.set(++next, callback); return next; }, clear(handle: unknown) { pending.delete(Number(handle)); }, fire() { const callbacks = [...pending.values()]; pending.clear(); callbacks.forEach(callback => callback()); } };
}
function controls() {
  const timer = clock(), values: boolean[] = []; let focused = false;
  const view = new PlayerControls({ visible: value => values.push(value), focused: () => focused }, timer);
  return { view, timer, values, focus(value: boolean) { focused = value; } };
}
test('idle playing controls hide, pointer/key wake resets deadline, and Close cancels every timer', () => {
  const h = controls(); h.view.open(); assert.equal(h.timer.pending.size, 0);
  h.view.setState('playing'); h.timer.fire(); assert.equal(h.values.at(-1), false);
  h.view.wake(); assert.equal(h.values.at(-1), true); assert.equal(h.timer.pending.size, 1);
  const old = [...h.timer.pending.values()][0]; h.view.close(); assert.equal(h.timer.pending.size, 0); old(); assert.equal(h.values.at(-1), false);
});
test('a queued old idle callback cannot hide replacement playback controls', () => {
  const h=controls();h.view.open();h.view.setState('playing');const old=[...h.timer.pending.values()][0];
  h.view.close();h.view.open();h.view.setState('playing');old();assert.equal(h.values.at(-1),true);assert.equal(h.timer.pending.size,1);h.view.close();
});
for (const state of ['preparing', 'buffering', 'paused', 'ended', 'error'] as const) test(state + ' keeps relevant controls visible without an idle timer', () => {
  const h = controls(); h.view.open(); h.view.setState('playing'); h.view.setState(state); h.timer.fire();
  assert.equal(h.values.at(-1), true); assert.equal(h.timer.pending.size, 0);
});
test('keyboard focus and an open format panel prevent idle controls from disappearing', () => {
  const h = controls(); h.view.open(); h.view.setState('playing'); h.focus(true); h.timer.fire(); assert.equal(h.values.at(-1), true);
  h.focus(false); h.view.wake(); h.view.setPanel(true); h.timer.fire(); assert.equal(h.values.at(-1), true);
  h.view.setPanel(false); h.timer.fire(); assert.equal(h.values.at(-1), false);
});

class ElementFixture extends EventTarget {
  attrs = new Map<string,string>(); dataset: Record<string,string> = {}; hidden = false; tabIndex = -1; parent?: ElementFixture;
  overlays: ElementFixture[] = []; controls: any = []; nativeControls = true; styleVisibility = 'visible'; isConnected = true;
  rect = { left: 0, top: 0, width: 44, height: 44 }; requestCount = 0;
  tagName: string; ownerDocument: any;
  constructor(tagName = 'DIV', ownerDocument: any = undefined) { super(); this.tagName=tagName; this.ownerDocument=ownerDocument; }
  setAttribute(name: string,value: string) { this.attrs.set(name,value); }
  getAttribute(name: string) { return this.attrs.get(name) ?? null; }
  removeAttribute(name: string) { this.attrs.delete(name); }
  toggleAttribute(name: string,value: boolean) { if(value)this.attrs.set(name,'');else this.attrs.delete(name); }
  contains(node: any): boolean { return node === this || !!node?.parent && this.contains(node.parent); }
  closest(selector: string): any {
    if (selector.includes('[hidden]') && this.hidden || selector.includes('[inert]') && this.attrs.has('inert') || selector.includes('[aria-hidden') && this.attrs.get('aria-hidden') === 'true') return this;
    return this.parent?.closest(selector) ?? null;
  }
  matches(selector: string) { return selector.includes(this.tagName.toLowerCase()); }
  querySelector() { return null; }
  querySelectorAll(selector: string) { return selector === '[data-player-overlay]' ? this.overlays : this.controls; }
  focus() { this.ownerDocument.activeElement = this; }
  blur() { this.ownerDocument.activeElement = null; }
  getBoundingClientRect() { return this.rect; }
  scrollIntoView() {}
  async requestFullscreen() { this.requestCount++; this.ownerDocument.fullscreenElement = this; }
}
function dom() {
  const doc: any = new EventTarget(); doc.activeElement = null; doc.fullscreenElement = null; doc.documentElement = { dataset: { layout: 'standard' } }; doc.exits = 0;
  doc.exitFullscreen = async () => { doc.exits++; doc.fullscreenElement = null; };
  const player = new ElementFixture('SECTION',doc), video = new ElementFixture('VIDEO',doc), header = new ElementFixture('HEADER',doc), footer = new ElementFixture('FOOTER',doc), background = new ElementFixture('MAIN',doc);
  video.controls = true;
  player.hidden = true; video.parent = player; header.parent = player; footer.parent = player; player.overlays = [header,footer];
  return { doc, player, video, header, footer, background };
}
test('player-container fullscreen retains overlays; Close exits only owned fullscreen, and denial does not select video fullscreen', async () => {
  const h = dom(); await togglePlayerFullscreen(h.player as any); assert.equal(h.doc.fullscreenElement,h.player); assert.equal(h.player.requestCount,1); assert.equal(h.video.requestCount,0);
  await togglePlayerFullscreen(h.player as any); assert.equal(h.doc.fullscreenElement,null); assert.equal(h.doc.exits,1);
  h.doc.fullscreenElement = h.background; await exitPlayerFullscreen(h.player as any); assert.equal(h.doc.exits,1);
  h.doc.fullscreenElement = h.video; await exitPlayerFullscreen(h.player as any); assert.equal(h.doc.exits,2);
  h.player.requestFullscreen = async () => { throw new Error('Denied'); }; await assert.rejects(togglePlayerFullscreen(h.player as any),/Denied/); assert.equal(h.video.requestCount,0);
});
test('native-video fullscreen classification is distinct from the complete app player', () => {
  assert.equal(nativeVideoFullscreen({ tagName: 'VIDEO' } as any),true); assert.equal(nativeVideoFullscreen({ tagName:'SECTION' } as any),false); assert.equal(nativeVideoFullscreen(null),false);
});
test('presentation uses inert/hidden semantics, wakes on real events and releases backgrounds/listeners on disposal', async () => {
  const h = dom(), view = installPlayerPresentation(h.player as any,h.video as any,[h.background as any]);
  view.open(); assert.equal(h.player.hidden,false); assert.equal(h.background.attrs.has('inert'),true); assert.equal(h.doc.activeElement,h.video);
  view.setPanel(true); assert.equal(h.video.attrs.has('inert'),true); assert.equal(h.header.attrs.get('aria-hidden'),'true');
  view.setPanel(false); assert.equal(h.video.attrs.has('inert'),false); assert.equal(h.header.attrs.has('inert'),false);
  for(const name of ['pointermove','pointerdown','keydown','focusin']) { h.player.dataset.controls='hidden'; h.player.dispatchEvent(new Event(name)); assert.equal(h.player.dataset.controls,'visible'); }
  view.dispose(); assert.equal(h.player.hidden,true); assert.equal(h.background.attrs.has('inert'),false); assert.equal(h.background.attrs.has('aria-hidden'),false);
  h.player.dataset.controls='sentinel';h.player.dispatchEvent(new Event('pointermove'));await Promise.resolve();assert.equal(h.player.dataset.controls,'sentinel');
});
function globals(h: ReturnType<typeof dom>, fn: () => void) {
  const original = Object.getOwnPropertyDescriptor(globalThis,'document'), style = Object.getOwnPropertyDescriptor(globalThis,'getComputedStyle');
  Object.defineProperty(globalThis,'document',{configurable:true,value:h.doc});Object.defineProperty(globalThis,'getComputedStyle',{configurable:true,value:(node:any)=>({visibility:node.styleVisibility})});
  try { fn(); } finally { if(original)Object.defineProperty(globalThis,'document',original);else Reflect.deleteProperty(globalThis,'document');if(style)Object.defineProperty(globalThis,'getComputedStyle',style);else Reflect.deleteProperty(globalThis,'getComputedStyle'); }
}
function key(name: string) { const event = new Event('keydown',{cancelable:true});Object.defineProperties(event,{key:{value:name},shiftKey:{value:false}});return event; }
test('Tab and directional navigation work in container fullscreen but native video controls keep their own keys', () => {
  const h=dom(), first=new ElementFixture('BUTTON',h.doc), second=new ElementFixture('BUTTON',h.doc);first.parent=h.header;second.parent=h.footer;second.rect.left=100;
  h.player.hidden=false;h.player.controls=[first,second];h.player.setAttribute('role','dialog');h.doc.fullscreenElement=h.player;
  globals(h,()=>{installNavigation(()=>{},()=>h.player as any);h.doc.activeElement=first;const tab=key('Tab');h.doc.dispatchEvent(tab);assert.equal(h.doc.activeElement,second);assert.equal(tab.defaultPrevented,true);
    h.doc.activeElement=first;h.doc.dispatchEvent(key('ArrowRight'));assert.equal(h.doc.activeElement,second);
    h.doc.fullscreenElement=h.video;h.doc.activeElement=first;const native=key('Tab');h.doc.dispatchEvent(native);assert.equal(native.defaultPrevented,false);assert.equal(h.doc.activeElement,first);});
});
test('hidden, inert, zero-size and invisible controls cannot enter keyboard/spatial focus',()=>{
  const h=dom(),target=new ElementFixture('BUTTON',h.doc);h.player.hidden=false;target.parent=h.header;
  globals(h,()=>{assert.equal(navigationVisible(target as any),true);for(const attr of ['inert','aria-hidden']){h.header.setAttribute(attr,attr==='aria-hidden'?'true':'');assert.equal(navigationVisible(target as any),false);h.header.removeAttribute(attr);}h.header.hidden=true;assert.equal(navigationVisible(target as any),false);h.header.hidden=false;target.rect.width=0;assert.equal(navigationVisible(target as any),false);target.rect.width=44;target.styleVisibility='hidden';assert.equal(navigationVisible(target as any),false);});
});
test('cached page restore only occurs after persisted pageshow; suspend closes presentation and never resumes media',()=>{
  const target=new EventTarget(),calls:string[]=[];let playing=true,dialog=true,engineClosed=0;
  const remove=installPageCacheRecovery(target,{suspend(persisted){playing=false;dialog=false;engineClosed++;calls.push('hide:'+persisted);},restore(){calls.push('restore-library-focus');}});
  const transition=(name:string,persisted:boolean)=>{const event=new Event(name);Object.defineProperty(event,'persisted',{value:persisted});target.dispatchEvent(event);};
  transition('pagehide',true);assert.equal(playing,false);assert.equal(dialog,false);assert.equal(engineClosed,1);
  transition('pageshow',true);assert.deepEqual(calls,['hide:true','restore-library-focus']);assert.equal(playing,false);
  transition('pageshow',false);assert.equal(calls.length,2);remove();transition('pagehide',false);assert.equal(engineClosed,1);
});
test('actual CSS keeps the video full-viewport and all companion surfaces out of layout at every breakpoint',()=>{
  const css=postcss.parse(readFileSync(new URL('../src/styles/player.css',import.meta.url),'utf8'));
  const declarations=(selector:string)=>{const values=new Map<string,string>();css.walkRules(rule=>{if(rule.selectors.includes(selector))for(const node of rule.nodes)if(node.type==='decl')values.set(node.prop,node.value);});return values;};
  for(const selector of ['.player-content','.screen']){assert.equal(declarations(selector).get('position'),'absolute');assert.equal(declarations(selector).get('inset'),'0');}
  assert.equal(declarations('.player').get('position'),'fixed');assert.equal(declarations('.player').get('inset'),'0');
  for(const selector of ['.player-header','.player-companion','.player-format','.player-sync'])assert.equal(declarations(selector).get('position'),'absolute');
  assert.equal(declarations('.player .icon-button > span').get('display'),'none');
  const video=declarations('.screen video');assert.equal(video.get('width'),'100%');assert.equal(video.get('height'),'100%');assert.equal(video.get('object-fit'),'contain');
  assert.equal(declarations('.player[data-controls="hidden"] [data-player-overlay]').get('visibility'),'hidden');
  css.walkRules(rule=>{if(rule.selectors.some(s=>s==='.player'||s==='.player-content'||s==='.screen'))for(const node of rule.nodes)if(node.type==='decl')assert(!['flex-direction','grid-template-rows'].includes(node.prop));});
});

test('Format isolates the entire screen and restores the exact native control and focus policy',()=>{
  for(const enabled of [true,false]) {
    const h=dom(),screen=new ElementFixture('DIV',h.doc),close=new ElementFixture('BUTTON',h.doc);screen.parent=h.player;h.video.parent=screen;h.video.controls=enabled;
    h.player.querySelector=(selector:string)=>selector==='.screen'?screen:selector.includes('close-format')?close:null;
    const view=installPlayerPresentation(h.player as any,h.video as any,[h.background as any]);view.open();const before=h.video.tabIndex;
    view.setPanel(true);assert.equal(screen.attrs.has('inert'),true);assert.equal(screen.attrs.get('aria-hidden'),'true');assert.equal(h.video.controls,false);assert.equal(h.video.tabIndex,-1);
    const retry=new ElementFixture('BUTTON',h.doc);retry.parent=screen;assert.equal(playerActivationAllowed(retry as any),false);
    const focus=new Event('focusin');Object.defineProperty(focus,'target',{value:retry});h.doc.dispatchEvent(focus);assert.equal(h.doc.activeElement,close);
    view.setPanel(false);assert.equal(screen.attrs.has('inert'),false);assert.equal(h.video.controls,enabled);assert.equal(h.video.tabIndex,before);view.dispose();
  }
});
test('legacy inert activation is blocked while idle overlay wake makes a remote action reachable',()=>{
  const h=dom(),button=new ElementFixture('BUTTON',h.doc);button.parent=h.footer;
  const view=installPlayerPresentation(h.player as any,h.video as any,[]);view.open();h.footer.setAttribute('inert','');assert.equal(playerActivationAllowed(button as any),false);
  h.player.dispatchEvent(new Event('reel-player-wake'));assert.equal(playerActivationAllowed(button as any),true);view.dispose();
});
test('cached focus waits for navigation and rejects changed account/route owner before restoring or falling back',async()=>{
  for(const stale of [false,true]) {
    let resolve!:()=>void;const navigation=new Promise<void>(yes=>{resolve=yes;});let owner='A|route2',restores=0;
    const pending=restoreAfterNavigation(navigation,owner,()=>owner,()=>{restores++;});assert.equal(restores,0);
    if(stale)owner='B|route3';resolve();assert.equal(await pending,!stale);assert.equal(restores,stale?0:1);
  }
});
test('Format scroll consumes only movable directions so the boundary can reach Close',()=>{
  const panel={scrollTop:0,clientHeight:100,scrollHeight:300,scrollBy({top}:{top:number}){this.scrollTop=Math.max(0,Math.min(200,this.scrollTop+top));}};
  assert.equal(scrollFormatPanel(panel as any,-1),false);assert.equal(scrollFormatPanel(panel as any,1),true);assert.equal(panel.scrollTop,50);
  panel.scrollTop=200;assert.equal(scrollFormatPanel(panel as any,1),false);assert.equal(scrollFormatPanel(panel as any,-1,true),true);assert.equal(panel.scrollTop,120);
});
test('action status is inside active fullscreen player and outside a closed player',()=>{
  const h=dom();h.player.hidden=false;assert.equal(statusContainer(h.player as any,h.background as any,true),h.player);
  assert.equal(statusContainer(h.player as any,h.background as any,false),h.background);h.player.hidden=true;assert.equal(statusContainer(h.player as any,h.background as any,true),h.background);
});


test('timeline clock labels handle unloaded, negative, fractional and hour-long video', () => {
  for (const [value, label] of [[NaN, '0:00'], [Infinity, '0:00'], [-2, '0:00'], [5.9, '0:05'], [125, '2:05'], [3600, '1:00:00'], [3725, '1:02:05']] as const) assert.equal(playbackTime(value), label);
});

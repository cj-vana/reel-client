import { spawn } from 'node:child_process';
import { cp,mkdtemp,mkdir,readFile,writeFile,readdir,rm } from 'node:fs/promises';
import { createHash,randomBytes } from 'node:crypto';
import { resolve,join } from 'node:path';
import { tmpdir } from 'node:os';
import { chromium,expect } from '@playwright/test';
import { packageManifest } from './package-manifest.mjs';
import { assertPortFree,ownsListener,stopOwnedChild } from './runtime-ownership.mjs';
import { assertViewportPicture,assertFullscreenWindow } from './runtime-player-geometry.mjs';
import { root,sourceRevision } from './source-revision.mjs';
if(process.platform!=='darwin'||process.arch!=='arm64')throw new Error('Actual runtime harness targets macOS arm64 only');
const receipt=JSON.parse(await readFile(resolve(root,'.cache/package-qa-darwin-arm64.json'))),before=await sourceRevision();
if(receipt.desktopRevision!==before.revision)throw new Error('Package current desktop source first');
const app=resolve(root,receipt.packageDirectory,'Reel Desktop QA.app'),binary=resolve(app,'Contents/MacOS/Reel'),archive=resolve(app,'Contents/Resources/app.asar');
const digest=async file=>createHash('sha256').update(await readFile(file)).digest('hex');
if(await digest(archive)!==receipt.appAsarSha256 || (await packageManifest(resolve(root,receipt.packageDirectory))).sha256!==receipt.packageSha256)throw new Error('Package changed');
const profile=await mkdtemp(join(tmpdir(),'qa-profile-reel-')),owner=randomBytes(32).toString('hex'),children=[],logs=[],outcomes=[],origins=[];
await writeFile(join(profile,'.reel-qa-owner'),owner,{mode:0o600,flag:'wx'});
await mkdir(resolve(root,'.cache/runtime'),{recursive:true});
const original=await readFile(resolve(root,'../web/scripts/fixture-server.mjs'),'utf8');
const fixture=original.replace("origin === 'null'","origin === 'null' || origin === 'reel://app'");
if(fixture===original)throw new Error('Fixture CORS adapter mismatch');
const fixturePath=resolve(root,'.cache/runtime/fixture-server.mjs');await writeFile(fixturePath,fixture);
// Copy every module the fixture server imports from its own folder, so a new one cannot be left behind.
const fixtureModules=[...original.matchAll(/from '\.\/([a-z-]+\.mjs)'/g)].map(match=>match[1]);
if(!fixtureModules.includes('fixture-library.mjs'))throw new Error('Fixture module list mismatch');
for(const name of fixtureModules)await cp(resolve(root,'../web/scripts',name),resolve(root,'.cache/runtime',name));
function start(cmd,args,options={}){const child=spawn(cmd,args,{cwd:root,stdio:['ignore','pipe','pipe'],...options});children.push(child);for(const stream of[child.stdout,child.stderr])stream.on('data',chunk=>logs.push(chunk));return child;}
async function ready(url,child,port){const end=Date.now()+25000;while(Date.now()<end){try{if(ownsListener(child,port)&&(await fetch(url,{signal:AbortSignal.timeout(500)})).ok)return;}catch(error){if(child.exitCode!==null||child.signalCode!==null||error.message==='The loopback port belongs to another process')throw error;}await new Promise(resolve=>setTimeout(resolve,150));}throw new Error('Owned process readiness timeout');}
async function check(id,behavior,action){try{await action();outcomes.push({id,behavior,result:'passed'});}catch(error){outcomes.push({id,behavior,result:'blocked',error:String(error)});throw error;}}
let browser,exitCode=0;
try{
await assertPortFree(19670);await assertPortFree(19671);
const fixtureProcess=start(process.execPath,[fixturePath],{env:{...process.env,REEL_FIXTURE_PORT:'19671',REEL_FIXTURE_MEDIA:resolve(root,'.cache/fixture')}});await ready('http://127.0.0.1:19671/System/Info/Public',fixtureProcess,19671);
let processApp=start(binary,[`--reel-qa-profile=${profile}`,`--reel-qa-owner=${owner}`,'--reel-qa-port=19670',...(process.argv.includes('--visible')?['--reel-qa-visible']:[])]);await ready('http://127.0.0.1:19670/json/version',processApp,19670);
browser=await chromium.connectOverCDP('http://127.0.0.1:19670');let context=browser.contexts()[0],page=context.pages()[0];page.setDefaultTimeout(10000);
page.on('request',request=>origins.push(new URL(request.url()).origin));
await check('DR001','Packaged owned-origin launch renders session-only QA login without OS vault access',async()=>{await expect(page.locator('#connect-form')).toBeVisible({timeout:10000});expect(page.url()).toBe('reel://app/index.html');expect(await page.evaluate(()=>window.REEL_CONFIG)).toEqual({previewMode:true,appName:'Reel',platform:'desktop'});await expect(page.locator('[name=remember]')).toBeDisabled();await expect(page.locator('#connect-form')).toContainText('Quit and reopen Reel to retry secure storage.');});
await check('DR002','Renderer has no Node,Electron or generic native bridge',async()=>expect(await page.evaluate(()=>[typeof window.require,typeof window.process,typeof window.Buffer,typeof window.ipcRenderer])).toEqual(Array(4).fill('undefined')));
await check('DR003','Actual app protocol delivers CSP/notice bytes and rejects unknown/foreign paths',async()=>{const value=await page.evaluate(async()=>{const response=await fetch('reel://app/THIRD_PARTY_NOTICES.txt');return{text:await response.text(),csp:response.headers.get('content-security-policy'),unknown:(await fetch('reel://app/missing.js')).status,foreign:await fetch('reel://other/index.html').then(response=>response.status,()=>0)};});expect(value.text).toContain('hls.js');expect(value.csp).toContain("script-src 'self'");expect(value.csp).toContain("worker-src 'none'");expect(await page.locator('#pwa-tools').count()).toBe(0);const manifest=await page.evaluate(async()=>{const response=await fetch('reel://app/manifest.webmanifest');return{status:response.status,mime:response.headers.get('content-type')};});expect(manifest.status).toBe(200);expect(manifest.mime).toContain('application/manifest+json');expect(value.unknown).toBe(404);expect([0,404]).toContain(value.foreign);});
await check('DR004','CSP blocks inline script execution',async()=>{await page.evaluate(()=>{const script=document.createElement('script');script.textContent='window.__inlineRan=true';document.body.append(script);});expect(await page.evaluate(()=>window.__inlineRan)).toBeUndefined();});
await check('DR005','Popup creation denied',async()=>{const count=context.pages().length;expect(await page.evaluate(()=>window.open('https://example.invalid/')===null)).toBe(true);expect(context.pages().length).toBe(count);});
await check('DR006','Permission requests denied without OS prompt',async()=>{expect(await page.evaluate(()=>Notification.requestPermission())).toBe('denied');expect(await page.evaluate(async()=>{try{await navigator.mediaDevices.getUserMedia({audio:true});return'allowed';}catch(error){return error.name;}})).toBe('NotAllowedError');});
await check('DR007','Foreign navigation denied with owned document and native input still usable',async()=>{
await page.evaluate(()=>{location.href='https://example.invalid/';});
await expect.poll(()=>page.evaluate(()=>({url:location.href,state:document.readyState,form:!!document.querySelector('#connect-form')}))).toEqual({url:'reel://app/index.html',state:'complete',form:true});
// Chromium reports a provisional canceled navigation to CDP; use actual input to verify the retained page.
const point=await page.evaluate(()=>{const rect=document.querySelector('[name=username]').getBoundingClientRect();return{x:rect.x+20,y:rect.y+10};});
const cdp=await context.newCDPSession(page);await cdp.send('Input.dispatchMouseEvent',{type:'mousePressed',...point,button:'left',clickCount:1});await cdp.send('Input.dispatchMouseEvent',{type:'mouseReleased',...point,button:'left',clickCount:1});await cdp.send('Input.insertText',{text:'navigation-probe'});
expect(await page.evaluate(()=>document.querySelector('[name=username]').value)).toBe('navigation-probe');await cdp.detach();
await page.reload({waitUntil:'domcontentloaded'});await expect(page.locator('#connect-form')).toBeVisible();});

async function playbackFormat(method,delivery){
const video=page.locator('#video'),panel=page.locator('#player-format');
await page.getByRole('button',{name:'Playback options',exact:true}).click();await expect(panel).toBeVisible();
await page.getByText('Stream details',{exact:true}).click();
await expect(page.locator('#player-method')).toHaveText(method);
await expect(page.locator('#player-format-data')).toContainText(delivery);
await expect(page.locator('#player-format-data')).toContainText('Output:');
expect(await video.evaluate(element=>element.controls)).toBe(false);
await expect(page.locator('.screen')).toHaveAttribute('inert','');
await page.getByRole('button',{name:'Close playback options',exact:true}).click();await expect(panel).toBeHidden();
expect(await video.evaluate(element=>element.controls)).toBe(true);
expect(await page.locator('.screen').getAttribute('inert')).toBeNull();
await expect(page.getByRole('button',{name:'Playback options',exact:true})).toBeFocused();
}
async function playerSnapshot(name){
const snapshot=await page.evaluate(()=>{
const rect=element=>{const r=element.getBoundingClientRect();return{x:r.x,y:r.y,width:r.width,height:r.height};};
const player=document.querySelector('#player'),video=document.querySelector('#video');
return{fullscreen:document.fullscreenElement?.id??null,viewport:{width:innerWidth,height:innerHeight},screen:{width:screen.width,height:screen.height},
player:rect(player),video:{...rect(video),fit:getComputedStyle(video).objectFit,paused:video.paused,time:video.currentTime,controls:video.controls},
controls:player.dataset.controls,overlays:[...player.querySelectorAll('[data-player-overlay]')].map(element=>({inert:element.hasAttribute('inert'),ariaHidden:element.getAttribute('aria-hidden'),visibility:getComputedStyle(element).visibility}))};
});
snapshot.nativeWindow = nativeWindowState();
await writeFile(resolve(root,`.cache/runtime/player-${name}.json`),JSON.stringify(snapshot,null,2)+'\n');
await page.screenshot({path:resolve(root,`.cache/runtime/player-${name}.png`)});return snapshot;
}
function nativeWindowState(){
  const rows=Buffer.concat(logs).toString('utf8').split('\n').filter(line=>line.startsWith('REEL_QA_WINDOW '));
  return rows.length?JSON.parse(rows.at(-1).slice('REEL_QA_WINDOW '.length)):null;
}

async function login(password='demo'){await page.locator('[name=server]').fill('http://127.0.0.1:19671');await page.locator('[name=username]').fill('desktop');await page.locator('[name=password]').fill(password);await page.getByRole('button',{name:'Enter your library'}).click();}
await check('DR008','Sign-in error and form recovery',async()=>{await login('wrong');await expect(page.locator('#connection-error')).not.toBeEmpty();await expect(page.getByRole('button',{name:'Enter your library'})).toBeEnabled();});
await check('DR009','Synthetic custom-origin sign-in opens Home',async()=>{await login();await expect(page.locator('.hero')).toBeVisible();});
await check('DR010','Packaged Library and Details controls',async()=>{await page.getByRole('button',{name:'Library',exact:true}).click();await page.getByRole('button',{name:'Load more titles'}).click();await page.locator('[data-action=detail][data-id=movie-1]').click();await expect(page.locator('.detail-intro h1')).toHaveText('The Quiet Earth');});
await check('DR011','Actual MP4 play,pause,seek and close controls',async()=>{await page.locator('.detail-intro [data-action=play]').click();await expect.poll(()=>page.locator('#video').evaluate(video=>video.currentTime)).toBeGreaterThan(.5);await playbackFormat('DIRECT PLAY','Original file requested');await page.locator('#video').focus();await page.keyboard.press('Space');await expect.poll(()=>page.locator('#video').evaluate(video=>video.paused)).toBe(true);await page.keyboard.press('ArrowRight');await expect.poll(()=>page.locator('#video').evaluate(video=>video.currentTime)).toBeGreaterThan(5);await page.locator('#player [data-action=close-player]').first().click();await expect(page.locator('#player')).toBeHidden();});
await check('DR012','Settings quality selects actual HLS playback',async()=>{await page.getByRole('button',{name:'Settings',exact:true}).click();await page.locator('#quality').selectOption('2000000');await page.getByRole('button',{name:'Library',exact:true}).click();await page.getByRole('button',{name:'Load more titles'}).click();await page.locator('[data-action=detail][data-id=movie-2]').click();await page.locator('.detail-intro [data-action=play]').click();await playbackFormat('HLS STREAM','Requested plan:');await expect.poll(()=>page.locator('#video').evaluate(video=>video.currentTime),{timeout:20000}).toBeGreaterThan(.5);await page.locator('#player [data-action=close-player]').first().click();});
await check('DR018','Packaged fullscreen window retains video geometry, idle overlays, Format isolation and normal return',async()=>{
await page.getByRole('button',{name:'Library',exact:true}).click();await page.getByRole('button',{name:'Load more titles'}).click();
await page.locator('[data-action=detail][data-id=movie-3]').click();await expect(page.locator('.detail-intro h1')).toHaveText('North of Nowhere');
await page.locator('.detail-intro [data-action=play]').click();
await expect.poll(()=>page.locator('#video').evaluate(video=>video.currentTime),{timeout:20000}).toBeGreaterThan(.5);
await page.locator('#video').focus();
const beforeIdle=await playerSnapshot('window-playing');assertViewportPicture(beforeIdle);expect(beforeIdle.video.controls).toBe(true);expect(beforeIdle.video.paused).toBe(false);
await expect(page.locator('#player')).toHaveAttribute('data-controls','hidden',{timeout:7000});
const hidden=await playerSnapshot('window-idle');assertViewportPicture(hidden);expect(hidden.video.paused).toBe(false);expect(hidden.video.time).toBeGreaterThan(beforeIdle.video.time+.3);
expect(hidden.overlays).toHaveLength(2);for(const overlay of hidden.overlays)expect(overlay).toEqual({inert:true,ariaHidden:'true',visibility:'hidden'});
await page.mouse.move(hidden.viewport.width/2+1,hidden.viewport.height/2);
await expect(page.locator('#player')).toHaveAttribute('data-controls','visible');
await expect(page.getByRole('button',{name:'Close player',exact:true})).toBeVisible();
await page.locator('#video').focus();await page.keyboard.press('Space');await expect.poll(()=>page.locator('#video').evaluate(video=>video.paused)).toBe(true);
const restored=await playerSnapshot('window-controls');assertViewportPicture(restored);for(const overlay of restored.overlays)expect(overlay).toEqual({inert:false,ariaHidden:'false',visibility:'visible'});
await page.getByRole('button',{name:'Full screen',exact:true}).click();
await expect.poll(()=>page.evaluate(()=>document.fullscreenElement?.id)).toBe('player');
await playerSnapshot('fullscreen-entering');
await expect.poll(async()=>{const native=nativeWindowState();if(!native?.fullscreen)return false;return page.evaluate(bounds=>Math.abs(innerWidth-bounds.width)<=1&&Math.abs(innerHeight-bounds.height)<=1,native.contentBounds);},{timeout:10000}).toBe(true);
const fullscreen=await playerSnapshot('fullscreen-ready');assertFullscreenWindow(fullscreen);expect(fullscreen.video.paused).toBe(true);expect(fullscreen.video.controls).toBe(true);
await expect(page.getByRole('button',{name:'Exit full screen',exact:true})).toBeVisible();
await page.getByRole('button',{name:'Playback options',exact:true}).click();await expect(page.locator('#player-format')).toBeVisible();
await expect(page.locator('.screen')).toHaveAttribute('inert','');expect(await page.locator('#video').evaluate(video=>video.controls)).toBe(false);
await page.keyboard.press('Tab');expect(await page.locator('#player-format').evaluate(panel=>panel.contains(document.activeElement))).toBe(true);
expect(await page.evaluate(()=>document.fullscreenElement?.contains(document.activeElement))).toBe(true);
const format=await playerSnapshot('fullscreen-format');assertViewportPicture(format);expect(format.fullscreen).toBe('player');
await page.keyboard.press('Escape');await expect(page.locator('#player-format')).toBeHidden();
await expect.poll(()=>page.evaluate(()=>document.fullscreenElement?.id)).toBe('player');
await expect(page.getByRole('button',{name:'Playback options',exact:true})).toBeFocused();
expect(await page.locator('#video').evaluate(video=>video.controls)).toBe(true);expect(await page.locator('.screen').getAttribute('inert')).toBeNull();
await page.getByRole('button',{name:'Exit full screen',exact:true}).click();await expect.poll(()=>page.evaluate(()=>document.fullscreenElement===null)).toBe(true);
await expect(page.locator('#player')).toBeVisible();expect(await page.locator('#video').evaluate(video=>video.paused)).toBe(true);
assertViewportPicture(await playerSnapshot('fullscreen-exited'));
await page.getByRole('button',{name:'Close player',exact:true}).click();await expect(page.locator('#player')).toBeHidden();
await expect(page.locator('.detail-intro h1')).toHaveText('North of Nowhere');expect(await page.evaluate(()=>document.fullscreenElement)).toBeNull();
});
await check('DR019','Closing fullscreen playback restores the normal window and title Details',async()=>{
await page.locator('.detail-intro [data-action=play]').click();await expect.poll(()=>page.locator('#video').evaluate(video=>video.currentTime),{timeout:20000}).toBeGreaterThan(.5);
await page.locator('#video').focus();await page.keyboard.press('Space');
await page.getByRole('button',{name:'Full screen',exact:true}).click();await expect.poll(()=>page.evaluate(()=>document.fullscreenElement?.id)).toBe('player');
await page.getByRole('button',{name:'Close player',exact:true}).click();await expect(page.locator('#player')).toBeHidden();await expect.poll(()=>page.evaluate(()=>document.fullscreenElement===null)).toBe(true);
await expect(page.locator('.detail-intro h1')).toHaveText('North of Nowhere');
});
await check('DR013','Search empty-result and recovery controls',async()=>{await page.getByRole('button',{name:'Search',exact:true}).click();await page.locator('#search').fill('nonexistentzz');await expect(page.getByRole('heading',{name:'No matching titles.'})).toBeVisible();await page.locator('#search').fill('quiet');await expect(page.locator('.media-card').first()).toBeVisible();});
await check('DR014','320px and desktop Search controls fit the available content and viewport',async()=>{
const cdp=await context.newCDPSession(page);
try{for(const width of[320,1440]){
await cdp.send('Emulation.setDeviceMetricsOverride',{width,height:900,deviceScaleFactor:1,mobile:false});
await expect(page.locator('#search-form')).toBeVisible();await expect(page.locator('#search')).toBeVisible();
const bounds=await page.evaluate(()=>{
  const box=element=>{const r=element.getBoundingClientRect();return{left:r.left,top:r.top,right:r.right,bottom:r.bottom,width:r.width,height:r.height};};
  const content=document.querySelector('#content'),header=document.querySelector('.browse-page'),form=document.querySelector('#search-form'),input=document.querySelector('#search');
  if(!content||!header||!form||!input)throw new Error('Search layout controls missing');
  const h=box(header),style=getComputedStyle(header);
  return{viewport:{width:innerWidth,height:innerHeight},documentWidth:document.documentElement.scrollWidth,content:box(content),available:{left:h.left+parseFloat(style.paddingLeft),right:h.right-parseFloat(style.paddingRight)},form:box(form),input:box(input)};
});
await writeFile(resolve(root,`.cache/runtime/layout-${width}.json`),JSON.stringify(bounds,null,2)+'\n');
await page.screenshot({path:resolve(root,`.cache/runtime/viewport-${width}.png`)});
expect(bounds.documentWidth).toBeLessThanOrEqual(bounds.viewport.width+1);
const left=Math.max(0,bounds.content.left,bounds.available.left),right=Math.min(bounds.viewport.width,bounds.content.right,bounds.available.right);
for(const box of[bounds.form,bounds.input]){expect(box.width).toBeGreaterThan(0);expect(box.height).toBeGreaterThan(0);expect(box.left).toBeGreaterThanOrEqual(left-1);expect(box.right).toBeLessThanOrEqual(right+1);expect(box.top).toBeGreaterThanOrEqual(-1);expect(box.bottom).toBeLessThanOrEqual(bounds.viewport.height+1);}
expect(bounds.input.left).toBeGreaterThanOrEqual(bounds.form.left-1);expect(bounds.input.right).toBeLessThanOrEqual(bounds.form.right+1);
expect(bounds.input.top).toBeGreaterThanOrEqual(bounds.form.top-1);expect(bounds.input.bottom).toBeLessThanOrEqual(bounds.form.bottom+1);
}}finally{await cdp.send('Emulation.clearDeviceMetricsOverride');await cdp.detach();}
});
await check('DR015','History-off sends no playing reports',async()=>{const state=await(await fetch('http://127.0.0.1:19671/qa/state')).json();expect(state.reports.filter(event=>event.path.startsWith('/Sessions/Playing'))).toEqual([]);});
await check('DR016','Second QA instance exits without replacing current app',async()=>{const second=start(binary,[`--reel-qa-profile=${profile}`,`--reel-qa-owner=${owner}`,'--reel-qa-port=19670',...(process.argv.includes('--visible')?['--reel-qa-visible']:[])]);const code=await new Promise((resolveExit,reject)=>{const timer=setTimeout(()=>reject(new Error('Second instance timeout')),8000);second.once('exit',code=>{clearTimeout(timer);resolveExit(code);});});expect(code).toBe(0);await expect(page.locator('#search')).toBeVisible();});
await check('DR017','Normal Quit and cold relaunch do not retain session-only browser credentials',async()=>{
if(process.argv.includes('--manual-quit'))console.log('Quit Reel Desktop QA from its native application menu within 60 seconds to verify cold relaunch.');
else await page.keyboard.press('Meta+q');
await expect.poll(()=>processApp.exitCode,{timeout:process.argv.includes('--manual-quit')?60000:10000}).toBe(0);
await browser.close();browser=undefined;processApp=start(binary,[`--reel-qa-profile=${profile}`,`--reel-qa-owner=${owner}`,'--reel-qa-port=19670',...(process.argv.includes('--visible')?['--reel-qa-visible']:[])]);await ready('http://127.0.0.1:19670/json/version',processApp,19670);browser=await chromium.connectOverCDP('http://127.0.0.1:19670');context=browser.contexts()[0];page=context.pages()[0];await expect(page.locator('#connect-form')).toBeVisible({timeout:30000});expect(await page.evaluate(()=>localStorage.getItem('reel.connections.v1'))).toBeNull();});
}catch(error){exitCode=1;console.error(error);}
finally{
if(browser)await browser.close().catch(()=>{});
const stopped = await Promise.all(children.map(child=>stopOwnedChild(child)));
if(!stopped.every(Boolean))exitCode=1;
const hits=[];async function scan(folder){for(const entry of await readdir(folder,{withFileTypes:true})){const file=join(folder,entry.name);if(entry.isDirectory())await scan(file);else if(entry.isFile()&&(await readFile(file)).includes(Buffer.from('fixture-desktop')))hits.push(file.slice(profile.length));}}await scan(profile);
const after=await sourceRevision(),packageUnchanged=await digest(archive)===receipt.appAsarSha256&&(await packageManifest(resolve(root,receipt.packageDirectory))).sha256===receipt.packageSha256;
if(hits.length||after.revision!==before.revision||!packageUnchanged)exitCode=1;
await writeFile(resolve(root,'.cache/runtime/run.log'),Buffer.concat(logs));
await writeFile(resolve(root,'.cache/runtime/receipt.json'),JSON.stringify({desktopRevision:before.revision,webRevision:receipt.webRevision,packageAsarSha256:receipt.appAsarSha256,packageSha256:receipt.packageSha256,sourceUnchanged:after.revision===before.revision,packageUnchanged,outcomes,origins:[...new Set(origins)],profilePlaintextHits:hits,fixtureOriginalSha256:createHash('sha256').update(original).digest('hex'),fixtureAdapterSha256:createHash('sha256').update(fixture).digest('hex'),ownedProcessesStopped:stopped.every(Boolean),visibleMode:process.argv.includes('--visible'),exitCode,recordedAt:new Date().toISOString()},null,2)+'\n');await rm(profile,{recursive:true,force:true});}
process.exitCode=exitCode;

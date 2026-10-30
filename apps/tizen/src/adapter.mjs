import {MEDIA_KEYS,supportedMediaKeys,mediaAction,legacyDirection,textEntry} from './policy.mjs';

export function nativeVideoOwnsFullscreen(doc) { return doc.fullscreenElement?.tagName==='VIDEO'; }

export function installTizenAdapter(win,doc) {
  const owner='__reelTizenAdapterInstalled';
  if(win[owner])return win[owner];
  let disposed=false,exitDialog=null,exitFocus=null,exiting=false,exitTimer=null;
  let noticeTimer=null,imeTimer=null,pendingIME=null,imeEpoch=0,lastFocus=null;
  let lastSaver=null,lastSeekTime=0;
  const registered=new Map(),ownedNames=new Set(),composing=new WeakSet(),forwarded=new WeakSet();
  const previousBridge=win.ReelTizen;
  const inputDevice=win.tizen&&win.tizen.tvinputdevice;
  const appManager=win.tizen&&win.tizen.application;
  const nativeExit=!!(appManager&&typeof appManager.getCurrentApplication==='function');
  const time=()=>win.performance&&win.performance.now?win.performance.now():Date.now();
  const visible=element=>!!(element&&element.isConnected&&!element.closest('[hidden]')&&element.getBoundingClientRect().width>0&&win.getComputedStyle(element).visibility!=='hidden');
  const player=()=>{const element=doc.querySelector('#player');return element&&!element.hidden?element:null;};
  const button=action=>{const root=player();return root&&root.querySelector('[data-action="'+action+'"]');};
  const click=element=>{if(element&&!element.disabled){const root=player();if(root&&root.contains(element)&&element.closest('[inert]'))root.dispatchEvent(new win.Event('reel-player-wake'));element.click();return true;}return false;};
  function notice(message,playback=false) {
    if(disposed)return;
    let element=doc.querySelector('#tizen-status');
    if(!element){element=doc.createElement('div');element.id='tizen-status';element.className='tizen-status';element.setAttribute('role','status');doc.body.append(element);}
    const activePlayer=playback&&player();
    const host=activePlayer&&(activePlayer.querySelector('.player-content')||activePlayer)||doc.body;
    if(element.parentNode!==host)host.append(element);
    element.textContent=message;element.hidden=false;
    if(noticeTimer)win.clearTimeout(noticeTimer);
    noticeTimer=win.setTimeout(()=>{element.hidden=true;},7000);
  }
  function screenSaver(enabled,force=false) {
    const common=win.webapis&&win.webapis.appcommon;
    if(!force&&lastSaver===enabled)return;
    lastSaver=enabled;
    if(!common||typeof common.setScreenSaver!=='function'){
      if(!enabled)notice('The TV’s screen protection could not be updated. On-screen playback controls still work.',true);
      return;
    }
    const states=common.AppCommonScreenSaverState||{SCREEN_SAVER_ON:1,SCREEN_SAVER_OFF:0};
    try{common.setScreenSaver(enabled?states.SCREEN_SAVER_ON:states.SCREEN_SAVER_OFF,()=>{},()=>{if(lastSaver===enabled&&!disposed)notice('The TV’s screen protection could not be updated.',true);});}
    catch{if(!enabled)notice('The TV’s screen protection could not be updated.',true);}
  }
  function registerKeys() {
    if(disposed)return;
    if(!inputDevice||typeof inputDevice.getSupportedKeys!=='function'||typeof inputDevice.registerKey!=='function'){
      notice('TV remote services are unavailable in this preview. Keyboard and on-screen controls still work.');return;
    }
    let supported;
    try{supported=supportedMediaKeys(inputDevice.getSupportedKeys());}
    catch{notice('Some media buttons are unavailable. On-screen controls still work.');return;}
    for(const key of supported){
      if(ownedNames.has(key.name))continue;
      try{inputDevice.registerKey(key.name);ownedNames.add(key.name);registered.set(key.code,key.action);}
      catch{notice('Some media buttons are unavailable. On-screen controls still work.');}
    }
  }
  function unregisterKeys() {
    for(const name of Array.from(ownedNames)){
      try{
        if(!inputDevice||typeof inputDevice.unregisterKey!=='function')continue;
        inputDevice.unregisterKey(name);ownedNames.delete(name);
        const key=MEDIA_KEYS.find(key=>key.name===name);
        for(const [code,action]of registered)if(key&&action===key.action)registered.delete(code);
      }catch{}
    }
  }
  function keyboardVisibility(visibility) {
    doc.dispatchEvent(new win.CustomEvent('keyboardStateChange',{detail:{visibility}}));
  }
  function clearIME() {
    if(imeTimer)win.clearTimeout(imeTimer);
    imeTimer=null;pendingIME=null;imeEpoch++;
  }
  function finishIME(action,input,editor,epoch) {
    if(imeTimer)win.clearTimeout(imeTimer);
    imeTimer=win.setTimeout(()=>{
      imeTimer=null;
      if(disposed||doc.hidden||epoch!==imeEpoch||!input.isConnected)return;
      if(editor&&doc.querySelector('#tv-entry-editor')!==editor)return;
      keyboardVisibility(false);input.blur();
      if(editor)click(editor.querySelector(action==='done'?'#tv-entry-done':'#tv-entry-cancel'));
    },0);
  }
  function imeAction(event) {
    if(event.keyCode!==65376&&event.keyCode!==65385)return false;
    const editor=doc.querySelector('#tv-entry-editor');
    const input=textEntry(doc.activeElement)?doc.activeElement:(editor&&editor.querySelector('#tv-entry-input'));
    if(!input)return false;
    const action=event.keyCode===65376?'done':'cancel';
    if(event.isComposing||composing.has(input))pendingIME={action,input,editor,epoch:imeEpoch};
    else finishIME(action,input,editor,imeEpoch);
    // Native IME input defaults must remain intact, including Done and Cancel.
    return true;
  }
  function onFocusIn(event) {
    if(textEntry(event.target)){clearIME();keyboardVisibility(true);}
  }
  function onFocusOut(event) {if(textEntry(event.target))keyboardVisibility(false);}
  function onCompositionStart(event) {if(textEntry(event.target))composing.add(event.target);}
  function onCompositionEnd(event) {
    composing.delete(event.target);
    if(pendingIME&&pendingIME.input===event.target){const action=pendingIME;pendingIME=null;finishIME(action.action,action.input,action.editor,action.epoch);}
  }
  function restoreFocus(preferred) {
    if(visible(preferred)&&!textEntry(preferred)){preferred.focus({preventScroll:true});return;}
    if(visible(doc.activeElement)&&!textEntry(doc.activeElement))return;
    const target=Array.from(doc.querySelectorAll('button:not([disabled]),a[href]')).find(visible);
    if(target)target.focus({preventScroll:true});
  }
  function closeExit() {
    if(!exitDialog)return;
    if(exitTimer)win.clearTimeout(exitTimer);exitTimer=null;
    exitDialog.remove();exitDialog=null;exiting=false;
    registerKeys();restoreFocus(exitFocus);exitFocus=null;
  }
  function exitApplication() {
    if(exiting||!exitDialog||!nativeExit)return;
    exiting=true;
    const dialog=exitDialog,error=dialog.querySelector('[role="alert"]');
    for(const control of dialog.querySelectorAll('button'))control.disabled=true;
    error.textContent='Closing Reel…';screenSaver(true,true);unregisterKeys();
    const recover=()=>{
      if(disposed||exitDialog!==dialog)return;
      exiting=false;for(const control of dialog.querySelectorAll('button'))control.disabled=false;
      error.textContent='The TV did not close Reel. Try again, or choose Cancel.';
      registerKeys();dialog.querySelector('[data-tizen-cancel]').focus();
    };
    try{appManager.getCurrentApplication().exit();exitTimer=win.setTimeout(recover,3000);}
    catch{recover();}
  }
  function showExit() {
    if(disposed||exitDialog)return;
    exitFocus=doc.activeElement;
    exitDialog=doc.createElement('section');exitDialog.id='tizen-exit';exitDialog.className='tizen-exit';exitDialog.setAttribute('role','dialog');exitDialog.setAttribute('aria-modal','true');exitDialog.setAttribute('aria-labelledby','tizen-exit-title');
    exitDialog.innerHTML='<div class="tizen-exit-panel"><h2 id="tizen-exit-title">Close Reel?</h2><p>Your library will be here when you come back.</p><p class="tizen-exit-error" role="alert"></p><div class="tizen-exit-actions"><button type="button" class="button quiet" data-tizen-cancel>Cancel</button><button type="button" class="button primary" data-tizen-exit>Exit Reel</button></div></div>';
    exitDialog.querySelector('[data-tizen-cancel]').addEventListener('click',closeExit);
    const confirm=exitDialog.querySelector('[data-tizen-exit]');confirm.disabled=!nativeExit;confirm.addEventListener('click',exitApplication);
    if(!nativeExit)exitDialog.querySelector('[role="alert"]').textContent='TV exit is unavailable in this browser preview.';
    doc.body.append(exitDialog);exitDialog.querySelector('[data-tizen-cancel]').focus();
  }
  function exitKey(event) {
    if(!exitDialog)return false;
    const direction=legacyDirection(event)||event.key;
    const controls=Array.from(exitDialog.querySelectorAll('button:not([disabled])'));
    if(event.key==='Tab'||/^Arrow/.test(direction)){
      event.preventDefault();event.stopImmediatePropagation();
      if(controls.length){const index=controls.indexOf(doc.activeElement);const delta=event.shiftKey||direction==='ArrowLeft'||direction==='ArrowUp'?-1:1;controls[(index+delta+controls.length)%controls.length].focus();}return true;
    }
    if(event.keyCode===10009||event.key==='Escape'||event.key==='BrowserBack'){
      event.preventDefault();event.stopImmediatePropagation();if(!event.repeat&&!exiting)closeExit();return true;
    }
    if(event.keyCode===13||event.key==='Enter'){
      event.preventDefault();event.stopImmediatePropagation();if(!event.repeat)click(doc.activeElement);return true;
    }
    return false;
  }
  function forward(event,key) {
    event.preventDefault();event.stopImmediatePropagation();
    const target=event.target&&typeof event.target.dispatchEvent==='function'?event.target:doc;
    const normalized=new win.KeyboardEvent('keydown',{key,bubbles:true,cancelable:true,composed:true,repeat:event.repeat});
    forwarded.add(normalized);target.dispatchEvent(normalized);
  }
  function onKey(event) {
    if(disposed||doc.hidden||forwarded.has(event)||event.keyCode===10182)return;
    if(exitKey(event)||imeAction(event))return;
    if(textEntry(doc.activeElement)||textEntry(event.target)||event.isComposing){
      if(event.keyCode===10009||event.key==='BrowserBack')event.stopImmediatePropagation();
      return;
    }
    if(event.keyCode===10009){if(!event.repeat)forward(event,'BrowserBack');else{event.preventDefault();event.stopImmediatePropagation();}return;}
    const action=mediaAction(event,registered),root=player();
    if(action&&root){
      event.preventDefault();event.stopImmediatePropagation();
      const video=root.querySelector('#video');if(!video)return;
      if(action==='toggle'&&event.repeat)return;
      if((action==='forward'||action==='rewind')&&event.repeat&&time()-lastSeekTime<250)return;
      if(action==='toggle'||action==='play'&&video.paused||action==='pause'&&!video.paused)click(button('toggle-play'));
      else if(action==='stop')stopPlayback();
      else if(action==='forward'||action==='rewind'){lastSeekTime=time();click(button(action==='forward'?'skip-forward':'skip-back'));}
      return;
    }
    if(nativeVideoOwnsFullscreen(doc))return;
    const direction=legacyDirection(event);
    if(direction&&(doc.activeElement?.tagName==='SELECT'||event.target?.tagName==='SELECT'))return;
    if(direction&&event.key!==direction){forward(event,direction);return;}
    if(event.keyCode===13&&event.key!=='Enter'&&!event.repeat){
      const active=doc.activeElement;
      if(active&&active.matches('button,a[href]')){event.preventDefault();event.stopImmediatePropagation();click(active);}
    }
  }
  function stopPlayback() {
    const root=player();if(!root)return;
    const video=root.querySelector('#video');try{if(video)video.pause();}catch{}
    const format=root.querySelector('#player-format');
    if(format&&!format.hidden)click(format.querySelector('[data-action="close-format"]'));
    click(root.querySelector('[data-action="close-player"]'));
  }
  function hidden() {
    lastFocus=doc.activeElement;clearIME();
    const editor=doc.querySelector('#tv-entry-editor');if(editor)click(editor.querySelector('#tv-entry-cancel'));
    if(textEntry(doc.activeElement))doc.activeElement.blur();
    stopPlayback();screenSaver(true,true);unregisterKeys();
  }
  function shown() {
    if(disposed)return;registerKeys();restoreFocus(lastFocus);
    if(win.navigator&&win.navigator.onLine===false)notice('You’re offline. Reconnect, then try your library again.');
  }
  function onVisibility() {if(doc.hidden)hidden();else shown();}
  function onPlaying(event) {if(event.target&&event.target.id==='video')screenSaver(!(event.target.videoWidth>0));}
  function onStopped(event) {if(event.target&&event.target.id==='video')screenSaver(true);}
  function onOffline() {stopPlayback();screenSaver(true,true);notice('Connection lost. Reconnect, then try your library again.');}
  function onOnline() {if(!disposed&&!doc.hidden)notice('Connection restored. Your library is ready when you are.');}
  function onPageHide(event) {hidden();if(!event.persisted)dispose();}
  function onPageShow(event) {if(event.persisted)shown();}
  const bridge=Object.freeze({platformBack:showExit});
  win.ReelTizen=bridge;
  const listeners=[['keydown',onKey,true],['focusin',onFocusIn,true],['focusout',onFocusOut,true],['compositionstart',onCompositionStart,true],['compositionend',onCompositionEnd,true],['visibilitychange',onVisibility,false],['playing',onPlaying,true],['pause',onStopped,true],['ended',onStopped,true],['error',onStopped,true]];
  for(const [name,listener,capture] of listeners)doc.addEventListener(name,listener,capture);
  win.addEventListener('offline',onOffline);win.addEventListener('online',onOnline);win.addEventListener('pagehide',onPageHide);win.addEventListener('pageshow',onPageShow);
  function dispose() {
    if(disposed)return;clearIME();stopPlayback();screenSaver(true,true);unregisterKeys();
    disposed=true;if(noticeTimer)win.clearTimeout(noticeTimer);if(exitTimer)win.clearTimeout(exitTimer);
    for(const [name,listener,capture] of listeners)doc.removeEventListener(name,listener,capture);
    win.removeEventListener('offline',onOffline);win.removeEventListener('online',onOnline);win.removeEventListener('pagehide',onPageHide);win.removeEventListener('pageshow',onPageShow);
    if(exitDialog)exitDialog.remove();exitDialog=null;
    const status=doc.querySelector('#tizen-status');if(status)status.remove();
    if(win.ReelTizen===bridge){if(previousBridge===undefined)delete win.ReelTizen;else win.ReelTizen=previousBridge;}
    if(win[owner]===controller)delete win[owner];
  }
  const controller=Object.freeze({dispose});
  Object.defineProperty(win,owner,{value:controller,configurable:true});
  registerKeys();return controller;
}

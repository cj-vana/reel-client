import { randomUUID } from 'node:crypto';
import { APP_URL } from './policy.mjs';
export const CHANNEL='reel:desktop:v1';
export function installBridge(window,store,ipcMain,{saveConnections=(value,context)=>store.saveConnections(value,context),closeResources=()=>Promise.resolve()}={}){
  let epoch=0,closing=false,pendingClose;
  const contents=window.webContents;
  contents.on('did-start-navigation',(_event,_url,isInPlace,isMainFrame)=>{if(isMainFrame&&!isInPlace)epoch++;});
  const valid=(event,captured=epoch)=>{try{return !window.isDestroyed()&&!contents.isDestroyed()&&event.sender===contents&&event.senderFrame===contents.mainFrame&&event.senderFrame.url===APP_URL&&captured===epoch;}catch{return false;}};
  const handle=async(event,message)=>{
    if(!valid(event)||!message||typeof message!=='object'||Array.isArray(message))return{ok:false,code:'invalid'};
    const captured=epoch,context=()=>valid(event,captured);
    if(message.operation==='acknowledgeClose'&&Object.keys(message).length===2){if(!pendingClose||pendingClose.acknowledged||message.nonce!==pendingClose.nonce||pendingClose.epoch!==epoch)return{ok:false,code:'invalid'};pendingClose.acknowledged=true;pendingClose.resolve();return{ok:true};}
    // Only already queued nonsecret preference intents may drain before the close ack.
    // Renderer closing fences reject new intents; account writes are never admitted here.
    if(closing&&!(message.operation==='savePreferences'&&pendingClose&&!pendingClose.acknowledged))return{ok:false,code:'closing'};
    if(message.operation==='initialize'&&Object.keys(message).length===1){await store.initialize();await store.drain();return context()?store.snapshot():{ok:false,code:'closing'};}
    if(message.operation==='saveConnections'&&Object.keys(message).length===2)return saveConnections(message.value,context);
    if(message.operation==='savePreferences'&&Object.keys(message).length===2)return store.savePreferences(message.value,context);
    return{ok:false,code:'invalid'};
  };
  ipcMain.handle(CHANNEL,(event,message)=>handle(event,message).catch(()=>({ok:false,code:'io'})));
  window.once('closed',()=>{epoch++;closing=true;pendingClose?.resolve();pendingClose=undefined;ipcMain.removeHandler(CHANNEL);});
  return{
    requestClose:()=>{
      closing=true;if(pendingClose)return pendingClose.promise;if(contents.isDestroyed())return Promise.resolve();
      // Revoke noncredential leases synchronously before asking the renderer to drain.
      let resources;try{resources=Promise.resolve(closeResources());}catch(error){resources=Promise.reject(error);}void resources.catch(()=>{});
      let resolve;const acknowledgement=new Promise(done=>{resolve=done;});const promise=acknowledgement.then(async()=>{await store.drain();await resources;});const nonce=randomUUID();const record={nonce,promise,resolve,epoch,acknowledged:false};pendingClose=record;void promise.finally(()=>{if(pendingClose===record)pendingClose=undefined;}).catch(()=>{});contents.send('reel:close:v1',nonce);return promise;
    }
  };
}

import {APP_URL}from'./policy.mjs';
import {fields,validAccount,validGeneration,validRevision}from'./browse-schema.mjs';
export const BROWSE_CHANNEL='reel:browse-preferences:v1',BROWSE_NOTICE_CHANNEL='reel:browse-preferences:notice:v1';
export function installBrowseBridge(window,owner,ipcMain){
 const contents=window.webContents,session=owner.createSession();let epoch=0,closing=false;
 const valid=(event,captured=epoch)=>{try{return!closing&&!window.isDestroyed()&&!contents.isDestroyed()&&event.sender===contents&&event.senderFrame===contents.mainFrame&&event.senderFrame.url===APP_URL&&epoch===captured;}catch{return false;}};
 const handle=async(event,message)=>{
  if(!valid(event))return{ok:false,code:closing?'closing':'invalid'};const captured=epoch,context=()=>valid(event,captured);
  if(fields(message,['operation','generation'])&&message.operation==='revoke'&&validGeneration(message.generation))return session.revoke(message.generation);
  if(fields(message,['operation','account','generation'])&&message.operation==='open'&&validAccount(message.account)&&validGeneration(message.generation))return session.open(message.account,message.generation,context);
  if(fields(message,['operation','lease','expectedRevision','document'])&&message.operation==='commit'&&typeof message.lease==='string'&&message.lease.length===36&&validRevision(message.expectedRevision))return session.commit(message.lease,message.expectedRevision,message.document,context);
  if(fields(message,['operation','lease','expectedRevision'])&&message.operation==='reset'&&typeof message.lease==='string'&&message.lease.length===36&&validRevision(message.expectedRevision))return session.reset(message.lease,message.expectedRevision,context);
  if(fields(message,['operation'])&&message.operation==='notices')return{ok:true,notices:owner.snapshotNotices()};
  return{ok:false,code:'invalid'};
 };
 const notice=value=>{try{if(!closing&&!window.isDestroyed()&&!contents.isDestroyed()&&contents.mainFrame.url===APP_URL)contents.send(BROWSE_NOTICE_CHANNEL,value);}catch{/* No late publication into a destroyed view. */}};
 owner.listeners.add(notice);ipcMain.handle(BROWSE_CHANNEL,async(event,message)=>{
  let result;try{result=await handle(event,message);}catch{result={ok:false,code:'io'};}
  return message?.operation==='open'&&!result.ok?{...result,canReset:result.canReset===true,notices:result.notices??[]}:result;
 });
 contents.on('did-start-navigation',(_event,_url,isInPlace,isMainFrame)=>{if(isMainFrame&&!isInPlace){epoch++;session.lease=null;session.generation=-1;}});
 window.once('closed',()=>{closing=true;epoch++;session.dispose();owner.listeners.delete(notice);ipcMain.removeHandler(BROWSE_CHANNEL);});
 return{beginClose:()=>{closing=true;session.close();return owner.drain();},session};
}

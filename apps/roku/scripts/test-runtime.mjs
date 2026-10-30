import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
mkdirSync(path.join(root,'evidence'),{recursive:true});
const sha = p => createHash('sha256').update(readFileSync(path.join(root,p))).digest('hex');
const account = {server:'https://media.example/jellyfin', userId:'fixture-user', name:'Fixture viewer', username:'viewer', serverName:'Fixture A', token:'fixture-token-a', history:false};
const item = {Id:'movie-001',Name:'Fixture movie',Type:'Movie',RunTimeTicks:9000000000,UserData:{PlaybackPositionTicks:900000000}};
const info = {PlaySessionId:'fixture-session', MediaSources:[{Id:'fixture-source',SupportsDirectPlay:true,TranscodingUrl:'/jellyfin/Videos/movie-001/master.m3u8?api_key=fixture-token-a&PlaySessionId=fixture-session'}]};
const options = {start:90,forceHLS:false};
const plan = {accountKey:account.server+'|'+account.userId,itemId:item.Id,sourceId:'fixture-source',sessionId:'fixture-session',method:'Transcode',offset:90};
const cases=[];const expectations=new Map();const requests=new Map();const ledger=[];
function add(id,op,args,check,expectedRequests=[]){cases.push({id,op,args,responses:[]});expectations.set(id,check);requests.set(id,expectedRequests);}
const ok=v=>assert.equal(v.ok,true);const bad=v=>assert.equal(v.ok,false);const equal=expected=>value=>assert.deepEqual(value,expected);
for(const value of ['https://media.example',' HTTPS://MEDIA.EXAMPLE:443/jellyfin/ ','https://[::1]:8920/jellyfin'])add('address-accept-'+cases.length,'normalize',{value},ok);
for(const value of ['media.example','ftp://media.example','https://u:p@media.example','https://media.example?api_key=secret','https://media.example/#x','https://media.example/../x','https://media.example/%2e%2e','https://media.example:0','https://media.example:65536','https://media.example\\evil','http://remote.example','http://192.168.1.999'])add('address-reject-'+cases.length,'normalize',{value},bad);
for(const value of ['http://192.168.1.2:8096','http://10.0.0.2','http://172.16.0.2','http://100.64.0.2','http://jellyfin.local','http://[::1]:8096'])add('local-http-'+cases.length,'normalize',{value},v=>{ok(v);assert.equal(v.insecure,true)});
add('default-port-base-normalized','normalize',{value:'https://MEDIA.EXAMPLE:443/jellyfin/'},v=>assert.equal(v.url,account.server));
for(const resource of ['Items/a','/Items/a',account.server+'/Items/a'])add('resource-safe-'+cases.length,'scope',{server:account.server,path:resource},v=>{ok(v);assert.equal(v.url,account.server+'/Items/a')});
for(const resource of ['https://foreign.example/a','//foreign.example/a','https://media.example.evil/a','https://u:p@media.example/a','https://media.example/other/a','../secret','%2e%2e/secret','%252e%252e/secret','a\\b','javascript:alert(1)','a#fragment'])add('resource-refuse-'+cases.length,'scope',{server:account.server,path:resource},bad);
add('encode-unicode','encode',{value:'café & 東京 /'},equal(encodeURIComponent('café & 東京 /')));
add('auth-valid','auth',{server:account.server,username:'viewer',auth:{AccessToken:account.token,User:{Id:account.userId,Name:account.name}},info:{ServerName:'Fixture A'}},v=>{ok(v);assert.equal(v.account.history,false);assert.equal(v.account.token,account.token)});
for(const auth of [null,{}, {AccessToken:'',User:{Id:'u',Name:'n'}},{AccessToken:'a',User:{Id:'',Name:'n'}},{AccessToken:'a',User:{Id:'u'}}])add('auth-malformed-'+cases.length,'auth',{server:account.server,username:'viewer',auth,info:{}},bad);
add('metadata-no-credentials','metadata',{accounts:[{...account,password:'fixture-password',bitrate:6000000}],device:'fixture-device'},v=>{assert.equal(v.accounts[0].bitrate,6000000);assert.equal(v.accounts[0].token,undefined);assert.equal(v.accounts[0].password,undefined)});
add('restore-drops-injected-secrets','restore',{value:{device:'fixture-device',accounts:[{...account,password:'fixture-password'},account,{...account,server:'ftp://bad'}]}},v=>{assert.equal(v.accounts.length,1);assert.equal(v.accounts[0].token,'');assert.equal(v.accounts[0].password,undefined)});
for(const value of [null,'bad',[],{accounts:'bad'}])add('restore-corrupt-'+cases.length,'restore',{value},v=>assert.deepEqual(v.accounts,[]));
add('restore-eight-limit','restore',{value:{accounts:Array.from({length:10},(_,i)=>({...account,userId:'u'+i}))}},v=>assert.equal(v.accounts.length,8));
add('dto-deduplicate-invalid','items',{value:{Items:[item,item,null,{},'bad',{Id:'episode-1',Name:'Episode'}]}},v=>assert.deepEqual(v.map(i=>i.Id),[item.Id,'episode-1']));
add('append-deduplicate','append',{existing:[item],page:[item,{Id:'episode-1'}]},v=>assert.equal(v.length,2));
for(const [filter,type] of [['All','Movie,Series'],['Movies','Movie'],['Series','Series'],['Episodes','Episode']])add('library-filter-'+filter,'query',{account,options:{filter}},v=>{assert.equal(v.includeItemTypes,type);assert.equal(v.userId,account.userId);assert.equal(v.limit,60)});
for(const [sort,by,order] of [['Name','SortName','Ascending'],['Recently added','DateCreated','Descending'],['Year','ProductionYear','Descending']])add('library-sort-'+sort,'query',{account,options:{sort}},v=>{assert.equal(v.sortBy,by);assert.equal(v.sortOrder,order)});
add('paging-beyond-300','query',{account,options:{start:360,search:'café'}},v=>{assert.equal(v.startIndex,360);assert.equal(v.searchTerm,'café')});
add('paging-negative','query',{account,options:{start:-60}},v=>assert.equal(v.startIndex,0));
add('resume-position','resume',{item},equal(90));
for(const tick of [-10000000,8990000000,100000000000000])add('resume-safe-'+tick,'resume',{item:{...item,UserData:{PlaybackPositionTicks:tick}}},equal(0));
add('resume-missing','resume',{item:{}},equal(0));
add('playback-conservative-profile','body',{account,options},v=>{assert.equal(v.EnableDirectPlay,true);assert.equal(v.AutoOpenLiveStream,false);assert.equal(v.StartTimeTicks,900000000);assert.equal(v.DeviceProfile.TranscodingProfiles[0].VideoCodec,'h264')});
add('track-zero-not-dropped','body',{account,options:{...options,audio:0,subtitle:0}},v=>{assert.equal(v.AudioStreamIndex,0);assert.equal(v.SubtitleStreamIndex,0);assert.equal(v.EnableDirectPlay,false)});
add('subtitle-explicit-off','body',{account,options:{...options,subtitle:-1}},v=>assert.equal(v.SubtitleStreamIndex,-1));
add('direct-plan-resume','plan',{account,item,info,options,device:'fixture-device'},v=>{ok(v);assert.equal(v.method,'DirectPlay');assert.equal(v.playStart,90);assert.equal(v.offset,0);assert.equal(new URL(v.url).searchParams.get('static'),'true')});
add('hls-plan-no-double-seek','plan',{account,item,info,options:{...options,forceHLS:true},device:'fixture-device'},v=>{ok(v);assert.equal(v.format,'hls');assert.equal(v.playStart,0);assert.equal(v.offset,90);assert.equal(new URL(v.url).searchParams.get('api_key'),null);assert.equal(new URL(v.url).searchParams.get('StartTimeTicks'),'900000000');assert.equal(new URL(v.url).searchParams.get('PlaySessionId'),info.PlaySessionId)});
for(const data of [{}, {...info,PlaySessionId:''},{...info,MediaSources:[]},{...info,MediaSources:[{Id:'s',TranscodingUrl:'https://foreign.example/master.m3u8'}]}])add('playback-refuse-'+cases.length,'plan',{account,item,info:data,options:{...options,forceHLS:true},device:'fixture-device'},bad);
add('selected-source-body','body',{account,options:{...options,source:'source-b'}},v=>assert.equal(v.MediaSourceId,'source-b'));
add('wrong-source-refused','plan',{account,item,info,options:{...options,source:'source-b'},device:'fixture-device'},bad);
add('hls-overrides-stale-query','plan',{account,item,info:{...info,MediaSources:[{Id:'fixture-source',TranscodingUrl:'/jellyfin/Videos/movie-001/master.m3u8?StartTimeTicks=0&PlaySessionId=old&%61pi_key=wrong'}]},options:{...options,forceHLS:true},device:'fixture-device'},v=>{ok(v);const q=new URL(v.url).searchParams;assert.equal(q.get('StartTimeTicks'),'900000000');assert.equal(q.getAll('StartTimeTicks').length,1);assert.equal(q.get('PlaySessionId'),'fixture-session');assert.equal(q.get('api_key'),null)});
const fmt=(id,args,expected)=>add('format-'+id,'format',args,equal(expected));
for(const [seconds,text] of [[0,''],[0.4,''],[14,'14s'],[59,'59s'],[60,'1m'],[90,'2m'],[3600,'1h'],[6720,'1h 52m']])fmt('runtime-'+seconds,{fn:'runtime',seconds},text);
const richMovie={Type:'Movie',ProductionYear:2019,OfficialRating:'PG-13',RunTimeTicks:67200000000,MediaSources:[{MediaStreams:[{Type:'Video',Width:3840,Height:2160,VideoRangeType:'DOVIWithHDR10'},{Type:'Audio',Channels:6,DisplayTitle:'English Dolby Atmos 5.1'},{Type:'Subtitle'}]}]};
fmt('meta-movie-badges',{fn:'metaLine',item:richMovie},'2019   PG-13   1h 52m   4K   Dolby Vision   5.1   Atmos   CC');
fmt('meta-episode',{fn:'metaLine',item:{Type:'Episode',SeriesName:'Show',Name:'Pilot',IndexNumber:3,ParentIndexNumber:2,RunTimeTicks:27000000000}},'S2 E3   Pilot   45m');
fmt('meta-no-streams-no-badges',{fn:'metaLine',item:{Type:'Movie',ProductionYear:2020,RunTimeTicks:140000000}},'2020   14s');
fmt('meta-sub-minute-never-shows-less-than',{fn:'metaLine',item:{Type:'Movie',RunTimeTicks:1000}},'');
fmt('meta-parts-box-rating-and-badges-star-the-score',{fn:'metaParts',item:{...richMovie,CommunityRating:7.6}},[{kind:'text',text:'2019'},{kind:'badge',text:'PG-13'},{kind:'text',text:'1h 52m'},{kind:'star',text:'7.6'},...['4K','Dolby Vision','5.1','Atmos','CC'].map(text=>({kind:'badge',text}))]);
fmt('meta-star-whole-score-keeps-one-decimal',{fn:'metaLine',item:{Type:'Series',ProductionYear:2026,CommunityRating:8}},'2026   Series   8.0');
fmt('meta-star-out-of-range-hidden',{fn:'metaLine',item:{Type:'Movie',ProductionYear:2026,CommunityRating:12}},'2026');
const seasonPair=[{Id:'season-a',IndexNumber:1},{Id:'season-b',IndexNumber:2}];
fmt('next-up-season-by-id',{fn:'nextUpSeason',seasons:seasonPair,episode:{SeasonId:'season-b',ParentIndexNumber:1}},seasonPair[1]);
fmt('next-up-season-by-number',{fn:'nextUpSeason',seasons:seasonPair,episode:{ParentIndexNumber:2}},seasonPair[1]);
fmt('next-up-season-defaults-to-first',{fn:'nextUpSeason',seasons:seasonPair,episode:null},seasonPair[0]);
fmt('next-up-season-none-before-load',{fn:'nextUpSeason',seasons:[],episode:{SeasonId:'season-b'}},null);
for(const [view,filter,current,tab] of [['home','All',3,0],['library','Movies',0,1],['library','Series',0,2],['library','All',2,2],['search','All',0,3],['settings','All',0,4],['connections','All',0,4],['details','All',2,2]])fmt('tab-'+view+'-'+filter,{fn:'tabIndex',view,filter,current},tab);
const focusState=(over={})=>({rowIndex:0,actionIndex:0,navVisible:true,buttonsVisible:false,rowsVisible:false,actionsVisible:false,...over});
for(const [name,key,focus,state,route] of [
 ['rows-first-up-to-buttons','up','rows',focusState({buttonsVisible:true,rowsVisible:true}),'buttons'],
 ['rows-first-up-to-tabs','up','rows',focusState({rowsVisible:true}),'nav'],
 ['rows-later-up-stays','up','rows',focusState({rowIndex:1,rowsVisible:true}),''],
 ['actions-first-up-to-tabs','up','actions',focusState({actionsVisible:true}),'nav'],
 ['actions-later-up-stays','up','actions',focusState({actionIndex:2,actionsVisible:true}),''],
 ['buttons-up-to-tabs','up','buttons',focusState({buttonsVisible:true}),'nav'],
 ['tabs-down-to-buttons','down','nav',focusState({buttonsVisible:true,rowsVisible:true}),'buttons'],
 ['tabs-down-to-rows','down','nav',focusState({rowsVisible:true}),'rows'],
 ['tabs-down-to-actions','down','nav',focusState({actionsVisible:true}),'actions'],
 ['tabs-down-empty-stays','down','nav',focusState(),''],
 ['buttons-down-to-rows','down','buttons',focusState({buttonsVisible:true,rowsVisible:true}),'rows'],
 ['buttons-down-without-rows-stays','down','buttons',focusState({buttonsVisible:true}),''],
 ['left-is-never-routed','left','rows',focusState({rowsVisible:true}),'']])fmt('focus-'+name,{fn:'focusRoute',key,focus,state},route);
for(const [name,column,fromShape,toShape,count,remembered,expected] of [
 ['first-column',0,'wide','poster',9,null,0],['nearest-by-position',3,'wide','poster',9,null,6],['remembered-wins',3,'wide','poster',9,2,2],
 ['stale-memory-ignored',3,'wide','poster',9,12,6],['clamped-to-short-row',8,'poster','wide',3,null,2],['empty-row',2,'wide','poster',0,null,0]])fmt('landing-'+name,{fn:'landingColumn',column,fromShape,toShape,count,remembered},expected);
for(const [name,state,area] of [['buttons-first',{buttonsVisible:true,rowsVisible:true,actionsVisible:true},'buttons'],['rows',{rowsVisible:true,actionsVisible:true},'rows'],['actions',{actionsVisible:true},'actions'],['tabs-when-nothing',{},'nav']])fmt('restore-'+name,{fn:'restoreArea',state},area);
const resumable={Type:'Movie',ProductionYear:2021,RunTimeTicks:72000000000,UserData:{PlaybackPositionTicks:36000000000}};
fmt('progress-half',{fn:'progress',item:resumable},0.5);
fmt('progress-watched-is-zero',{fn:'progress',item:{...resumable,UserData:{Played:true,PlaybackPositionTicks:36000000000}}},0);
fmt('progress-percentage-fallback',{fn:'progress',item:{Type:'Movie',UserData:{PlayedPercentage:25}}},0.25);
fmt('card-detail-time-left',{fn:'cardDetail',item:resumable,showCode:true},'1h left');
fmt('card-detail-episode-code',{fn:'cardDetail',item:{Type:'Episode',IndexNumber:4,ParentIndexNumber:1},showCode:true},'S1 E4');
fmt('card-detail-episode-runtime',{fn:'cardDetail',item:{Type:'Episode',IndexNumber:4,RunTimeTicks:6000000000},showCode:false},'10m');
fmt('card-detail-year',{fn:'cardDetail',item:{...resumable,UserData:{}},showCode:true},'2021');
fmt('backdrop-own',{fn:'backdrop',item:{Id:'m1',BackdropImageTags:['t']}},'Items/m1/Images/Backdrop?maxWidth=1920&quality=80');
fmt('backdrop-parent',{fn:'backdrop',item:{Id:'e1',ParentBackdropItemId:'s1',ParentBackdropImageTags:['t']}},'Items/s1/Images/Backdrop?maxWidth=1920&quality=80');
fmt('backdrop-none',{fn:'backdrop',item:{Id:'e1'}},'');
fmt('backdrop-action-tile',{fn:'backdrop',item:{Id:'__more__',reelAction:'more'}},'');
fmt('artwork-poster-episode-uses-series',{fn:'artwork',item:{Id:'e1',Type:'Episode',SeriesId:'s1'},shape:'poster',width:320},'Items/s1/Images/Primary?maxWidth=320&quality=85');
fmt('artwork-wide-episode-still',{fn:'artwork',item:{Id:'e1',Type:'Episode',ImageTags:{Primary:'x'}},shape:'wide',width:480},'Items/e1/Images/Primary?maxWidth=480&quality=85');
fmt('artwork-wide-backdrop',{fn:'artwork',item:{Id:'m1',Type:'Movie',BackdropImageTags:['t']},shape:'wide',width:480},'Items/m1/Images/Backdrop?maxWidth=480&quality=85');
fmt('artwork-wide-falls-back-to-primary',{fn:'artwork',item:{Id:'m1',Type:'Movie'},shape:'wide',width:480},'Items/m1/Images/Primary?maxWidth=480&quality=85');
fmt('eyebrow-first-genre',{fn:'eyebrow',item:{Type:'Movie',Genres:['Drama','Crime','Thriller']}},'Drama');
fmt('eyebrow-none-for-episodes',{fn:'eyebrow',item:{Type:'Episode',Genres:['Drama']}},'');
fmt('eyebrow-none-without-genres',{fn:'eyebrow',item:{Type:'Series'}},'');
fmt('meta-series-says-series',{fn:'metaLine',item:{Type:'Series',ProductionYear:2023,OfficialRating:'TV-14',RunTimeTicks:31200000000}},'2023   TV-14   Series');
fmt('card-detail-shelf-episode-code-and-name',{fn:'cardDetail',item:{Type:'Episode',Name:'Manifest',IndexNumber:2,ParentIndexNumber:1,RunTimeTicks:36000000000,UserData:{PlaybackPositionTicks:6000000000}},showCode:true},'S1 E2 Manifest');
fmt('card-detail-episode-time-left',{fn:'cardDetail',item:{Type:'Episode',IndexNumber:4,RunTimeTicks:36000000000,UserData:{PlaybackPositionTicks:23400000000}},showCode:false},'21m left');
fmt('card-detail-episode-watched',{fn:'cardDetail',item:{Type:'Episode',IndexNumber:4,RunTimeTicks:31200000000,UserData:{Played:true}},showCode:false},'52m   Watched');
const dot=String.fromCodePoint(183);
for(const [bitrate,label] of [[20000000,'High '+dot+' 20 Mbps'],[8000000,'Balanced '+dot+' 8 Mbps'],[2000000,'Data saver '+dot+' 2 Mbps'],[12000000,'12 Mbps']])fmt('quality-label-'+bitrate,{fn:'qualityLabel',bitrate},label);
fmt('error-title-names-the-page',{fn:'errorTitle',kind:'home',expired:false},'Could not load Home');
fmt('error-title-expired-sign-in',{fn:'errorTitle',kind:'details',expired:true},'Sign in again');
for(const [shape,width,height,gap] of [['wide',384,216,32],['poster',192,288,24],['season',160,240,24]])fmt('shape-'+shape,{fn:'shape',shape},{width,height,gap,label:72,after:96,labelGap:32,maxWidth:shape==='wide'?480:320});
add('stale-generation','matches',{envelope:{accountKey:plan.accountKey,generation:1,nonce:2},key:plan.accountKey,generation:2,nonce:2},equal(false));
add('stale-account','matches',{envelope:{accountKey:plan.accountKey,generation:1,nonce:2},key:'https://other.example|fixture-user',generation:1,nonce:2},equal(false));
add('stale-request','matches',{envelope:{accountKey:plan.accountKey,generation:1,nonce:1},key:plan.accountKey,generation:1,nonce:2},equal(false));
add('current-response','matches',{envelope:{accountKey:plan.accountKey,generation:1,nonce:2},key:plan.accountKey,generation:1,nonce:2},equal(true));
for(const route of ['Sessions/Playing','Sessions/Playing/Progress','Sessions/Playing/Stopped','UserPlayedItems/movie-001','UserFavoriteItems/movie-001','arbitrary'])for(const method of ['POST','DELETE'])add('private-mutation-'+cases.length,'request',{account,device:'fixture-device',route,method},bad);
add('cleanup-broad-refused','request',{account,device:'fixture-device',route:'Videos/ActiveEncodings',method:'DELETE',query:{deviceId:'fixture-device'}},bad);
add('cross-account-report-refused','report',{account:{...account,history:true,server:'https://other.example'},plan,event:'start',position:5,paused:false,device:'fixture-device'},bad);
add('history-off-report-refused','report',{account,plan,event:'progress',position:5,paused:false,device:'fixture-device'},bad);
add('history-report-offset','report',{account:{...account,history:true},plan,event:'progress',position:5,paused:true,device:'fixture-device'},v=>{ok(v);assert.equal(v.body.PositionTicks,950000000);assert.equal(v.body.IsPaused,true)});
const other={...account,server:'https://other.example/jellyfin',token:'fixture-token-b',name:'Other fixture viewer'};
add('same-user-different-servers','upsert',{accounts:[account],incoming:other},v=>{ok(v);assert.equal(v.accounts.length,2);assert.equal(v.selected,1);assert.equal(v.accounts[0].token,account.token)});
add('reauth-preserves-own-preferences','upsert',{accounts:[{...account,history:true,bitrate:6000000},other],incoming:{...account,token:'fixture-token-new'}},v=>{ok(v);assert.equal(v.accounts.length,2);assert.equal(v.accounts[0].history,true);assert.equal(v.accounts[0].bitrate,6000000);assert.equal(v.accounts[1].token,other.token)});
add('remove-inactive-keeps-active','remove',{accounts:[account,other],index:0,active:1,remove:true},v=>{ok(v);assert.equal(v.selected,0);assert.equal(v.accounts[0].token,other.token);assert.equal(v.revoke.token,account.token)});
add('signout-active-fallback','remove',{accounts:[account,other],index:0,active:0,remove:false},v=>{ok(v);assert.equal(v.selected,1);assert.equal(v.accounts[0].token,'');assert.equal(v.accounts[1].token,other.token)});
add('remove-last-account','remove',{accounts:[account],index:0,active:0,remove:true},v=>{ok(v);assert.equal(v.selected,-1);assert.equal(v.accounts.length,0)});
add('remove-invalid-index','remove',{accounts:[account],index:3,active:0,remove:true},bad);
add('origin-specific-authorization','request',{account:other,device:'fixture-device',route:'Items',method:'GET'},v=>{ok(v);assert.equal(new URL(v.url).origin,'https://other.example');assert.ok(v.headers.Authorization.includes(other.token));assert.ok(!v.headers.Authorization.includes(account.token))});
add('dynamic-history-disable','historyAllowed',{accounts:[account],key:plan.accountKey},equal(false));
add('dynamic-history-enable','historyAllowed',{accounts:[{...account,history:true}],key:plan.accountKey},equal(true));
add('dynamic-history-expired-token','historyAllowed',{accounts:[{...account,history:true,token:''}],key:plan.accountKey},equal(false));
add('dynamic-history-foreign-origin','historyAllowed',{accounts:[{...account,history:true}],key:other.server+'|'+account.userId},equal(false));
const nativeRequest = (kind, extra={})=>({kind,account,device:'fixture-device',...extra});
function operation(id,args,expectedRequests,check=ok){add(id,'perform',args,check,expectedRequests)}
operation('operation-auth',nativeRequest('auth',{username:'viewer',password:'fixture-password',account:{server:account.server,token:'',userId:'',history:false}}),[
{route:'System/Info/Public',method:'GET'}, {route:'Users/AuthenticateByName',method:'POST',body:{Username:'viewer',Pw:'fixture-password'}}],v=>{ok(v);assert.equal(v.account.userId,account.userId)});
operation('operation-home-five-feeds',nativeRequest('home'),[
{route:'UserItems/Resume',method:'GET',query:{userId:account.userId,limit:18,mediaTypes:'Video',fields:'Overview,Genres',enableUserData:true}},
{route:'Shows/NextUp',method:'GET',query:{userId:account.userId,limit:18,fields:'Overview,Genres',enableUserData:true}},
...['Movie','Episode','Series'].map(type=>({route:'Items/Latest',method:'GET',query:{userId:account.userId,limit:18,includeItemTypes:type,...(type==='Episode'?{groupItems:false}:{}),fields:'Overview,Genres',enableUserData:true}}))],v=>{ok(v);assert.deepEqual(v.rows.map(r=>r.title),['Continue watching','Up next','Recently added movies','New episodes','Recently added series']);assert.equal(v.rows[3].title,'New episodes');assert.deepEqual(v.rows[3].items.slice(0,-1).map(x=>x.Id),['episode-new-2','episode-new-1']);assert.ok(v.rows[3].items.slice(0,-1).every(x=>x.Type==='Episode'));assert.equal(v.rows[3].items.at(-1).reelAction,'browse');assert.equal(v.rows[3].items.at(-1).filter,'Episodes')});
operation('operation-library-page',nativeRequest('library',{options:{filter:'Movies',sort:'Recently added',start:60}}),[{route:'Items',method:'GET',query:{userId:account.userId,recursive:true,includeItemTypes:'Movie',fields:'Overview,Genres',enableUserData:true,startIndex:60,limit:60,sortBy:'DateCreated',sortOrder:'Descending'}}],v=>{ok(v);assert.equal(v.items.length,15);assert.equal(v.total,75)});
operation('operation-search-empty',nativeRequest('search',{options:{search:'nothing'}}),[{route:'Items',method:'GET',query:{userId:account.userId,recursive:true,includeItemTypes:'Movie,Series,Episode',fields:'Overview,Genres',enableUserData:true,startIndex:0,limit:60,sortBy:'SortName',sortOrder:'Ascending',searchTerm:'nothing'}}],v=>{ok(v);assert.equal(v.items.length,0)});
operation('operation-details',nativeRequest('details',{itemId:item.Id}),[{route:'Items/'+item.Id,method:'GET',query:{userId:account.userId,fields:'Overview,Genres,MediaSources',enableUserData:true}}],v=>assert.equal(v.item.Id,item.Id));
// A series also asks for its next-up episode. The fixture, like the demo server, ignores seriesId and
// returns other series' episodes too, so the operation must keep only an episode of this series.
const seriesDetails=(id)=>[{route:'Items/'+id,method:'GET',query:{userId:account.userId,fields:'Overview,Genres,MediaSources',enableUserData:true}},{route:'Shows/NextUp',method:'GET',query:{userId:account.userId,seriesId:id,limit:1,fields:'Overview,Genres,MediaSources',enableUserData:true}}];
operation('operation-details-series-next-up',nativeRequest('details',{itemId:'series-1'}),seriesDetails('series-1'),v=>{ok(v);assert.equal(v.item.Id,'series-1');assert.equal(v.nextUp.Id,'episode-next-1')});
operation('operation-details-series-without-next-up',nativeRequest('details',{itemId:'series-2'}),seriesDetails('series-2'),v=>{ok(v);assert.equal(v.item.Id,'series-2');assert.equal(v.nextUp??null,null)});
operation('operation-seasons',nativeRequest('seasons',{itemId:'series-1'}),[{route:'Shows/series-1/Seasons',method:'GET',query:{userId:account.userId,fields:'Overview',enableUserData:true}}],v=>{ok(v);assert.equal(v.items[0].Id,'season-1');assert.equal(v.items.length,375);assert.equal(v.total,375)});
operation('operation-episodes',nativeRequest('episodes',{itemId:'season-1',seriesId:'series-1'}),[{route:'Shows/series-1/Episodes',method:'GET',query:{userId:account.userId,seasonId:'season-1',fields:'Overview',enableUserData:true,isMissing:false,startIndex:0,limit:60}}],v=>assert.equal(v.items[0].Id,'episode-1'));
operation('operation-seasons-start-does-not-invent-server-pagination',nativeRequest('seasons',{itemId:'series-1',start:360}),[{route:'Shows/series-1/Seasons',method:'GET',query:{userId:account.userId,fields:'Overview',enableUserData:true}}],v=>{ok(v);assert.equal(v.items.length,375);assert.equal(v.items.at(-1).Id,'season-375')});
operation('operation-episodes-page-2',nativeRequest('episodes',{itemId:'season-1',seriesId:'series-1',start:60}),[{route:'Shows/series-1/Episodes',method:'GET',query:{userId:account.userId,seasonId:'season-1',fields:'Overview',enableUserData:true,isMissing:false,startIndex:60,limit:60}}],v=>{ok(v);assert.equal(v.items[0].Id,'episode-61');assert.equal(v.items.length,15)});
operation('operation-playback-direct',nativeRequest('playback',{item,options}),[{route:'Items/'+item.Id+'/PlaybackInfo',method:'POST',bodyCheck:b=>{assert.equal(b.EnableDirectPlay,true);assert.equal(b.StartTimeTicks,900000000);assert.equal(b.DeviceProfile.TranscodingProfiles[0].VideoCodec,'h264')}}],v=>{ok(v);assert.equal(v.method,'DirectPlay')});
operation('operation-playback-hls-track',nativeRequest('playback',{item,options:{...options,audio:0,subtitle:-1,forceHLS:true}}),[{route:'Items/'+item.Id+'/PlaybackInfo',method:'POST',bodyCheck:b=>{assert.equal(b.AudioStreamIndex,0);assert.equal(b.SubtitleStreamIndex,-1);assert.equal(b.EnableDirectPlay,false)}}],v=>{ok(v);assert.equal(v.method,'Transcode')});
operation('operation-private-no-effect',nativeRequest('report',{plan,event:'progress',position:8,paused:false}),[],bad);
for(const event of ['start','progress','stopped'])operation('operation-report-'+event,nativeRequest('report',{account:{...account,history:true},plan,event,position:5,paused:event==='progress'}),[{route:'Sessions/Playing'+(event==='start'?'':'/'+(event==='progress'?'Progress':'Stopped')),method:'POST',bodyCheck:b=>assert.equal(b.PositionTicks,950000000)}]);
operation('operation-cleanup-owned',nativeRequest('cleanup',{plan}),[{route:'Videos/ActiveEncodings',method:'DELETE',query:{deviceId:'fixture-device',playSessionId:plan.sessionId}}]);
operation('operation-logout',nativeRequest('logout'),[{route:'Sessions/Logout',method:'POST'}]);
// Transport errors and malformed payloads are replayed through the exact production operation code.
add('operation-home-partial','perform',nativeRequest('home'),v=>{ok(v);assert.equal(v.failures.length,1);assert.equal(v.rows.length,4)});
add('operation-home-all-failed','perform',nativeRequest('home'),bad);
add('operation-permission-expired','perform',nativeRequest('home'),v=>{bad(v);assert.equal(v.expired,true)});
add('operation-invalid-page','perform',nativeRequest('library',{options:{}}),bad);
add('operation-wrong-details','perform',nativeRequest('details',{itemId:item.Id}),bad);
const capacityAccounts=Array.from({length:8},(_,i)=>({...account,userId:'saved-'+i,token:'saved-token-'+i}));
add('reject-ninth-auth-captures-only-issued-token','acceptAuth',{accounts:capacityAccounts,incoming:{...account,userId:'ninth',token:'new-unaccepted-token'}},v=>{bad(v);assert.equal(v.revoke.token,'new-unaccepted-token');assert.equal(v.revoke.userId,'ninth');assert.equal(v.accounts,undefined)});
add('accept-existing-auth-no-revoke','acceptAuth',{accounts:capacityAccounts,incoming:{...capacityAccounts[0],token:'renewed'}},v=>{ok(v);assert.equal(v.revoke,undefined);assert.equal(v.accounts[0].token,'renewed');assert.deepEqual(v.accounts.slice(1).map(a=>a.token),capacityAccounts.slice(1).map(a=>a.token))});
const seasons=Array.from({length:375},(_,i)=>({Id:'season-'+(i+1),Type:'Season'}));
add('dto-retains-complete-375-seasons','items',{value:{Items:seasons}},v=>{assert.equal(v.length,375);assert.equal(v.at(-1).Id,'season-375')});
for(const start of [0,60,300,360,999])add('local-season-page-'+start,'localPage',{items:seasons,start},v=>{const offset=start===999?360:start;assert.equal(v.start,offset);assert.equal(v.total,375);assert.deepEqual(v.items.map(x=>x.Id),seasons.slice(offset,offset+60).map(x=>x.Id))});
add('local-season-page-empty','localPage',{items:[],start:60},equal({items:[],start:0,total:0}));
const metadata={version:1,device:'fixture-device',accounts:[{server:account.server,username:account.username,name:account.name,serverName:account.serverName,userId:account.userId,history:false,bitrate:12000000}]};
for(const [id,read,state,canSave] of [
 ['absent',{ok:true,exists:false},'absent',true],['valid',{ok:true,exists:true,raw:JSON.stringify(metadata)},'valid',true],
 ['existing-empty',{ok:true,exists:true,raw:''},'corrupt',false],['corrupt',{ok:true,exists:true,raw:'{bad'},'corrupt',false],
 ['version',{ok:true,exists:true,raw:JSON.stringify({...metadata,version:2})},'unsupported-version',false],
 ['version-object',{ok:true,exists:true,raw:JSON.stringify({...metadata,version:{future:1}})},'unsupported-version',false],
 ['schema',{ok:true,exists:true,raw:JSON.stringify({...metadata,accounts:'wrong'})},'invalid-schema',false],
 ['unknown-field',{ok:true,exists:true,raw:JSON.stringify({...metadata,future:true})},'invalid-schema',false],
 ['account-unknown-field',{ok:true,exists:true,raw:JSON.stringify({...metadata,accounts:[{...metadata.accounts[0],token:'do-not-save'}]})},'invalid-schema',false],
 ['read-failed',{ok:false},'read-failed',false]
]){
 add('registry-decode-'+id,'registryDecode',{read},v=>{ok(v);assert.equal(v.state,state);assert.equal(v.canSave,canSave);if(canSave&&state==='valid')assert.equal(v.metadata.accounts[0].token,'')});
 add('operation-load-storage-'+id,'perform',nativeRequest('loadMetadata'),v=>{ok(v);assert.equal(v.state,state);assert.equal(v.canSave,canSave)});cases.at(-1).storageRead=read;cases.at(-1).expectedStorage=[{operation:'read'}];
 if(!canSave){add('operation-preserve-storage-'+id,'perform',nativeRequest('saveMetadata',{accounts:[account]}),bad);cases.at(-1).storageRead=read;cases.at(-1).expectedStorage=[{operation:'read'}]}
}
for(const [id,read,reset,success,writes] of [
 ['normal',{ok:true,exists:true,raw:JSON.stringify(metadata)},false,true,true],
 ['absent',{ok:true,exists:false},false,true,true],
 ['write-fails',{ok:true,exists:false},false,false,true],
 ['confirmed-reset',{ok:true,exists:true,raw:'{bad'},true,true,true],
 ['confirmed-reset-read-still-fails',{ok:false},true,false,false]
]){
 add('operation-save-storage-'+id,'perform',nativeRequest('saveMetadata',{accounts:[account],reset}),success?ok:bad);const c=cases.at(-1);c.storageRead=read;c.storageWrite={ok:success,error:'Synthetic storage failure'};c.expectedStorage=[{operation:'read'},...(writes?[{operation:'write'}]:[])];
}
const enqueue=(name)=>({kind:'enqueue',accounts:[{...account,name}]});const begin={kind:'begin'};
const complete=(revision,ok)=>({kind:'complete',revision,ok});const exit=canSave=>({kind:'exit',canSave});
function scenario(id,actions,check){add(id,'metadataScenario',{actions},check)}
scenario('save-fails-before-exit-retains-dirty',[enqueue('first'),begin,complete(1,false),exit(true)],v=>{assert.equal(v.queue.failed,true);assert.equal(v.queue.desired.metadata.accounts[0].name,'first');assert.equal(v.steps.at(-2).exit,'confirm')});
scenario('save-latest-wins-during-failure',[enqueue('old'),begin,enqueue('latest'),complete(1,false),begin],v=>{assert.equal(v.queue.desired.revision,2);assert.equal(v.queue.desired.metadata.accounts[0].name,'latest');assert.equal(v.steps.at(-2).begin,null)});
scenario('save-explicit-retry-latest',[enqueue('old'),begin,enqueue('latest'),complete(1,false),{kind:'retry'},begin,complete(2,true),exit(true)],v=>{assert.equal(v.queue.desired,null);assert.equal(v.queue.durable,2);assert.equal(v.steps.at(-2).exit,'close')});
scenario('save-success-does-not-clear-newer',[enqueue('old'),begin,enqueue('latest'),complete(1,true)],v=>{assert.equal(v.queue.desired.revision,2);assert.equal(v.queue.durable,1)});
scenario('save-stale-ack-ignored',[enqueue('first'),begin,complete(9,true)],v=>{assert.equal(v.queue.inflight,1);assert.equal(v.queue.durable,0);assert.notEqual(v.queue.desired,null)});
scenario('exit-waits-inflight',[enqueue('first'),begin,exit(true)],v=>assert.equal(v.steps.at(-2).exit,'wait'));
scenario('exit-session-only-confirms',[enqueue('first'),exit(false)],v=>assert.equal(v.steps.at(-2).exit,'confirm'));
scenario('exit-clean-no-write',[exit(true)],v=>assert.equal(v.steps.at(-2).exit,'close'));
scenario('exit-dirty-requests-save',[enqueue('first'),exit(true)],v=>assert.equal(v.steps.at(-2).exit,'save'));
add('revoke-old-target-survives-generation','revokeNotice',{source:{account,job:'old-job',generation:1},result:{ok:false},currentGeneration:8,currentAccount:other},v=>{assert.equal(v.id,'old-job');assert.equal(v.accountKey,plan.accountKey);assert.equal(v.account.token,account.token);assert.ok(v.label.includes(account.name));assert.notEqual(v.account.token,other.token)});
add('revoke-retry-keeps-target-id','revokeNotice',{source:{account,job:'new-job',revocationId:'old-job'},result:{ok:false}},v=>assert.equal(v.id,'old-job'));
add('revoke-success-no-warning','revokeNotice',{source:{account,job:'j'},result:{ok:true}},equal(null));
for(const closing of [false,true])for(const visible of [false,true])add('player-start-gate-'+closing+'-'+visible,'canStart',{closing,visible},equal(!closing&&!visible));
for(const state of ['playing','stopping','stopped','finished','error'])for(const closing of [false,true])add('player-release-gate-'+closing+'-'+state,'canRelease',{closing,state},equal(closing&&state==='stopped'));
const savedA={...metadata.accounts[0],userId:'saved-a',username:'saved-a',name:'Recovered A',history:true,bitrate:6000000};
const currentB={...account,userId:'session-b',username:'session-b',name:'Session B',token:'current-b-token',history:false,bitrate:2000000};
const normalizedKey=a=>new URL(a.server).toString().replace(/\/$/,'').toLowerCase()+'|'+a.userId;
const savedRead=accounts=>({ok:true,exists:true,raw:JSON.stringify({version:1,device:'saved-device',accounts})});
add('recovery-union-retains-A-and-active-B','reconcileRecovery',{saved:[savedA],current:[currentB],activeKey:normalizedKey(currentB)},v=>{ok(v);assert.deepEqual(v.accounts.map(a=>a.userId),['saved-a','session-b']);assert.equal(v.selected,1);assert.equal(v.accounts[1].token,currentB.token);assert.equal(v.accounts[0].token,'')});
add('recovery-same-key-current-preferences-and-token-win','reconcileRecovery',{saved:[savedA],current:[{...savedA,history:false,bitrate:20000000,token:'active-same-key'}],activeKey:normalizedKey(savedA)},v=>{ok(v);assert.equal(v.accounts.length,1);assert.equal(v.accounts[0].history,false);assert.equal(v.accounts[0].bitrate,20000000);assert.equal(v.accounts[0].token,'active-same-key');assert.equal(v.selected,0)});
add('recovery-normalized-server-identity','reconcileRecovery',{saved:[savedA],current:[{...savedA,server:'https://MEDIA.EXAMPLE:443/jellyfin/',token:'active-normalized'}],activeKey:normalizedKey(savedA)},v=>{ok(v);assert.equal(v.accounts.length,1);assert.equal(v.accounts[0].server,account.server);assert.equal(v.accounts[0].token,'active-normalized');assert.equal(v.selected,0)});
add('recovery-identical-user-different-server-kept','reconcileRecovery',{saved:[savedA],current:[{...savedA,server:other.server,token:'active-other-origin'}],activeKey:other.server+'|'+savedA.userId},v=>{ok(v);assert.equal(v.accounts.length,2);assert.equal(v.selected,1);assert.equal(v.accounts[0].server,account.server);assert.equal(v.accounts[1].token,'active-other-origin')});
const eightSaved=Array.from({length:8},(_,i)=>({...savedA,userId:'saved-'+i}));
for(const [id,saved,current,success]of [
 ['union-success',[savedA],[currentB],true],
 ['same-key-success',[savedA],[{...savedA,token:'active-same',history:false,bitrate:20000000}],true],
 ['exact-capacity-success',eightSaved.slice(0,7),[currentB],true],
 ['overflow-preserve',eightSaved,[currentB],false],
 ['overflow-after-session-removal-fits',eightSaved,[],true]
]){
 const activeKey=current.length?normalizedKey(current[0]):'';
 add('recovery-flow-'+id,'recoveryFlow',{current,activeKey},v=>{
  assert.equal(v.first.state,'read-failed');assert.equal(v.first.canSave,false);assert.deepEqual(v.pendingBeforeRecovery.metadata.accounts.map(a=>a.userId),current.map(a=>a.userId));
  assert.equal(v.merged.ok,success);
  if(success){assert.equal(v.write.ok,true);assert.equal(v.queue.desired,null);assert.equal(v.exitDecision,'close');assert.equal(v.persisted.state,'valid');assert.equal(v.persisted.metadata.accounts.length,v.merged.accounts.length);assert.ok(v.persisted.metadata.accounts.every(a=>a.token===''));assert.deepEqual(v.persisted.metadata.accounts.map(a=>a.userId),v.merged.accounts.map(a=>a.userId));if(current.length){assert.equal(v.merged.accounts[v.merged.selected].token,current[0].token);assert.equal(v.persisted.metadata.accounts.find(a=>a.userId===current[0].userId).bitrate,current[0].bitrate)}}
  else{assert.equal(v.merged.capacity,true);assert.equal(v.merged.count,9);assert.equal(v.write,null);assert.equal(v.persisted,null);assert.equal(v.queue.desired.metadata.accounts[0].userId,currentB.userId);assert.equal(v.exitDecision,'confirm')}
 });const c=cases.at(-1);c.storageReads=[{ok:false},savedRead(saved),savedRead(saved)];c.storageWrite={ok:true};c.expectedStorage=[{operation:'read'},{operation:'read'},...(success?[{operation:'read'},{operation:'write'}]:[])];c.expectedSavedUserIds=[...new Set([...saved.map(a=>a.userId),...current.map(a=>a.userId)])];
}
add('recovery-read-still-fails-no-write','recoveryFlow',{current:[currentB],activeKey:normalizedKey(currentB)},v=>{assert.equal(v.first.canSave,false);assert.equal(v.recovered.canSave,false);assert.equal(v.merged,null);assert.equal(v.write,null);assert.equal(v.queue.desired.metadata.accounts[0].userId,currentB.userId);assert.equal(v.exitDecision,'confirm')});cases.at(-1).storageReads=[{ok:false},{ok:false}];cases.at(-1).expectedStorage=[{operation:'read'},{operation:'read'}];
const episodeItems=[1,2,3].map(n=>({Id:'episode-'+n,Name:'Episode '+n,Type:'Episode',SeriesId:'series-1',SeasonId:'season-1',IndexNumber:n,RunTimeTicks:9000000000}));
const currentEpisode=episodeItems[1];
add('episode-neighbors-middle','episodeNeighbors',{items:episodeItems,item:currentEpisode},equal({previous:episodeItems[0],next:episodeItems[2]}));
add('episode-neighbors-first','episodeNeighbors',{items:episodeItems,item:episodeItems[0]},equal({previous:null,next:episodeItems[1]}));
add('episode-neighbors-last','episodeNeighbors',{items:episodeItems,item:episodeItems[2]},equal({previous:episodeItems[1],next:null}));
for(const [name,items]of [['missing-current',[episodeItems[0],episodeItems[2]]],['duplicate',[...episodeItems,currentEpisode]],['foreign',[episodeItems[0],currentEpisode,{...episodeItems[2],SeriesId:'other'}]],['missing-media',[episodeItems[0],currentEpisode,{...episodeItems[2],IsMissing:true}]],['malformed',[null]],['empty',[]]])add('episode-neighbors-'+name,'episodeNeighbors',{items,item:currentEpisode},equal({previous:null,next:null}));
const introSegment={ItemId:item.Id,Type:'Intro',StartTicks:100000000,EndTicks:300000000};
add('intro-real-metadata','introTarget',{items:[introSegment],item,position:15,offset:0,duration:900},equal(30));
add('intro-hls-relative-seek','introTarget',{items:[introSegment],item,position:15,offset:12,duration:888},equal(18));
for(const [name,segments,position]of [['before',[introSegment],9],['after',[introSegment],30],['no-metadata',[],15],['chapter-name-only',[{Name:'Intro',StartPositionTicks:100000000}],15],['foreign',[{...introSegment,ItemId:'other'}],15],['credits',[{...introSegment,Type:'Outro'}],15],['negative',[{...introSegment,StartTicks:-1}],15],['reversed',[{...introSegment,EndTicks:1}],15],['past-duration',[{...introSegment,EndTicks:999999999999}],15],['wrong-type',[{...introSegment,EndTicks:'300000000'}],15]])add('intro-reject-'+name,'introTarget',{items:segments,item,position,offset:0,duration:900},equal(-1));
for(const [name,source]of [['current',{accountKey:plan.accountKey,generation:3,playerEpoch:4}],['account',{accountKey:'foreign',generation:3,playerEpoch:4}],['generation',{accountKey:plan.accountKey,generation:2,playerEpoch:4}],['epoch',{accountKey:plan.accountKey,generation:3,playerEpoch:3}],['absent',null]])add('player-response-'+name,'playerMatches',{source,key:plan.accountKey,generation:3,epoch:4},equal(name==='current'));
const advance={reason:'finished',stopped:true,enabled:true,item:currentEpisode,nextItem:episodeItems[2],key:plan.accountKey,owner:plan.accountKey};
add('autonext-confirmed-finish','autoNextAllowed',advance,equal(true));
for(const [name,change]of [['cancel',{reason:'back'}],['error',{reason:'error'}],['stopping',{stopped:false}],['disabled',{enabled:false}],['last-episode',{nextItem:null}],['same-episode',{nextItem:currentEpisode}],['account-switch',{key:'foreign'}],['foreign-series',{nextItem:{...episodeItems[2],SeriesId:'other'}}]])add('autonext-reject-'+name,'autoNextAllowed',{...advance,...change},equal(false));
add('autonext-preference-save','metadata',{accounts:[{...account,autoNext:false}],device:'fixture-device'},v=>assert.equal(v.accounts[0].autoNext,false));
add('autonext-preference-restore','restore',{value:{accounts:[{...account,autoNext:false}]}},v=>assert.equal(v.accounts[0].autoNext,false));
add('autonext-preference-reauth','upsert',{accounts:[{...account,autoNext:false}],incoming:{...account,token:'new'}},v=>assert.equal(v.accounts[0].autoNext,false));
operation('operation-player-adjacent',nativeRequest('playerContext',{item:currentEpisode}),[{route:'Shows/series-1/Episodes',method:'GET',query:{userId:account.userId,adjacentTo:currentEpisode.Id,isMissing:false,fields:'Overview',enableUserData:true}}],v=>{ok(v);assert.equal(v.previous.Id,'episode-1');assert.equal(v.next.Id,'episode-3')});
operation('operation-player-intro',nativeRequest('playerIntro',{itemId:item.Id}),[{route:'MediaSegments/'+item.Id,method:'GET',query:{includeSegmentTypes:'Intro'}}],v=>{ok(v);assert.deepEqual(v.segments,[introSegment])});
operation('operation-player-detail',nativeRequest('playerDetail',{itemId:'episode-3'}),[{route:'Items/episode-3',method:'GET',query:{userId:account.userId,fields:'Overview,Genres,MediaSources',enableUserData:true}}],v=>{ok(v);assert.equal(v.item.Id,'episode-3')});
operation('operation-player-seasons',nativeRequest('playerSeasons',{itemId:'series-1'}),[{route:'Shows/series-1/Seasons',method:'GET',query:{userId:account.userId,fields:'Overview',enableUserData:true}}],v=>{ok(v);assert.equal(v.items.length,375);assert.equal(v.received,375)});
operation('operation-player-episodes',nativeRequest('playerEpisodes',{itemId:'season-1',seriesId:'series-1',start:60}),[{route:'Shows/series-1/Episodes',method:'GET',query:{userId:account.userId,seasonId:'season-1',fields:'Overview',enableUserData:true,isMissing:false,startIndex:60,limit:60}}],v=>{ok(v);assert.equal(v.items.length,15);assert.equal(v.received,15);assert.equal(v.total,75)});
const savedAutoplay={version:1,device:'fixture-device',accounts:[{server:account.server,userId:account.userId,username:account.username,name:account.name,serverName:account.serverName,history:false,bitrate:12000000,autoNext:false}]};
add('autonext-registry-valid','registryDecode',{read:{ok:true,exists:true,raw:JSON.stringify(savedAutoplay)}},v=>{assert.equal(v.canSave,true);assert.equal(v.metadata.accounts[0].autoNext,false)});
add('autonext-registry-malformed-preserved','registryDecode',{read:{ok:true,exists:true,raw:JSON.stringify({...savedAutoplay,accounts:[{...savedAutoplay.accounts[0],autoNext:'false'}]})}},v=>assert.equal(v.canSave,false));
add('intro-native-duration-overrun','introTarget',{items:[introSegment],item:{...item,RunTimeTicks:0},position:15,offset:0,duration:20},equal(-1));
add('intro-native-duration-unknown','introTarget',{items:[introSegment],item,position:15,offset:0,duration:0},equal(-1));
add('intro-native-hls-duration-overrun','introTarget',{items:[introSegment],item,position:15,offset:12,duration:10},equal(-1));
add('autonext-cancel-latch','autoNextAllowed',{...advance,cancelled:true},equal(false));
add('manual-selection-owns-eof','playerEndReason',{state:'finished',pending:'episode-1'},equal('episode'));
add('manual-selection-owns-old-error','playerEndReason',{state:'error',pending:'episode-1'},equal('episode'));
add('ordinary-natural-end','playerEndReason',{state:'finished',pending:''},equal('finished'));
const server=createServer(async(req,res)=>{
 let record;
 try{
  let body='';for await(const part of req)body+=part;
  const url=new URL(req.url,'http://fixture.invalid');
  assert.equal(url.pathname.startsWith('/jellyfin/'),true);
  const route=url.pathname.slice('/jellyfin/'.length);const data=body?JSON.parse(body):undefined;
  assert.ok(req.headers.authorization?.startsWith('MediaBrowser Client="Reel Roku"'));
  record={method:req.method,route,query:Object.fromEntries(url.searchParams),bodyKeys:data?Object.keys(data):[],authorizationSha256:createHash('sha256').update(req.headers.authorization).digest('hex')};record.phase=req.headers["x-reel-fixture-phase"]??"effect";ledger.push(record);
  let result;
  if(route==='System/Info/Public')result={ServerName:'Fixture A'};
  else if(route==='Users/AuthenticateByName'){assert.deepEqual(data,{Username:'viewer',Pw:'fixture-password'});result={AccessToken:account.token,User:{Id:account.userId,Name:account.name}}}
  else{
   assert.ok(req.headers.authorization.includes('Token="'+account.token+'"'));
   if(route==='Shows/NextUp'&&url.searchParams.has('seriesId')){const elsewhere={Id:'episode-elsewhere',Name:'Elsewhere',Type:'Episode',SeriesId:'series-other',IndexNumber:1,ParentIndexNumber:1};result={Items:url.searchParams.get('seriesId')==='series-1'?[elsewhere,{Id:'episode-next-1',Name:'Fixture next',Type:'Episode',SeriesId:'series-1',IndexNumber:2,ParentIndexNumber:1}]:[elsewhere]}}
   else if(route==='Items/series-1'||route==='Items/series-2')result={Id:route.slice('Items/'.length),Name:'Fixture series',Type:'Series'};
   else if(route==='UserItems/Resume'||route==='Shows/NextUp')result={Items:[item],TotalRecordCount:1};
   else if(route==='Items/Latest'){const type=url.searchParams.get('includeItemTypes');result=type==='Episode'?(url.searchParams.get('groupItems')==='false'?[{Id:'episode-new-2',Name:'Fixture episode 2',Type:'Episode',SeriesId:'series-group'},{Id:'episode-new-1',Name:'Fixture episode 1',Type:'Episode',SeriesId:'series-group'}]:[{Id:'series-group',Name:'Fixture grouped series',Type:'Series',ChildCount:2}]):[{...item,Id:type.toLowerCase()+'-latest',Type:type}]}
   else if(route==='Items'){const count=url.searchParams.get('searchTerm')==='nothing'?0:75;const start=Number(url.searchParams.get('startIndex')??0);result={Items:Array.from({length:Math.min(60,Math.max(0,count-start))},(_,i)=>({...item,Id:'movie-'+String(start+i+1).padStart(3,'0')})),TotalRecordCount:count}}
   else if(route==='Items/'+item.Id)result=item;
   else if(route==='Shows/series-1/Seasons'){assert.equal(url.searchParams.has('startIndex'),false);assert.equal(url.searchParams.has('limit'),false);result={Items:Array.from({length:375},(_,i)=>({Id:'season-'+(i+1),Name:'Fixture season',Type:'Season',SeriesId:'series-1'})),TotalRecordCount:375}}
   else if(route==='Shows/series-1/Episodes'&&url.searchParams.has('adjacentTo')){assert.equal(url.searchParams.get('adjacentTo'),'episode-2');assert.equal(url.searchParams.get('isMissing'),'false');result={Items:episodeItems}}
   else if(route==='MediaSegments/'+item.Id){assert.equal(url.searchParams.get('includeSegmentTypes'),'Intro');result={Items:[introSegment]}}
   else if(route==='Items/episode-3')result=episodeItems[2];
   else if(route==='Shows/series-1/Episodes'){assert.equal(url.searchParams.get('seasonId'),'season-1');const start=Number(url.searchParams.get('startIndex')??0);result={Items:Array.from({length:Math.min(60,Math.max(0,75-start))},(_,i)=>({Id:'episode-'+(start+i+1),Type:'Episode',Name:'Fixture episode'})),TotalRecordCount:75}}
   else if(route==='Items/'+item.Id+'/PlaybackInfo')result=info;
   else if(route.startsWith('Sessions/Playing')){assert.equal(req.method,'POST');if(req.headers['x-reel-fixture-phase']!=='prepare')assert.equal(data.PlaySessionId,plan.sessionId);result={}}
   else if(route==='Videos/ActiveEncodings'){assert.equal(req.method,'DELETE');assert.equal(url.searchParams.get('playSessionId'),plan.sessionId);result={}}
   else if(route==='Sessions/Logout'){assert.equal(req.method,'POST');result={}}
   else throw new Error('Unowned fixture route '+route);
  }
  record.responseCode=200;res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify(result));
 }catch(error){if(record)record.responseCode=500;res.writeHead(500);res.end(JSON.stringify({error:String(error)}))}
});
await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve)});
const origin='http://127.0.0.1:'+server.address().port;
try{
 for(const c of cases){
  for(const expected of requests.get(c.id)){
   const url=new URL(origin+'/jellyfin/'+expected.route);for(const [k,v]of Object.entries(expected.query??{}))url.searchParams.set(k,String(v));
   // Fixture responses are fetched on the actual owned loopback server, then replayed into BrightScript's transport seam.
   const auth='MediaBrowser Client="Reel Roku"'+(c.id==='operation-auth'?'':', Token="'+account.token+'"');
   const response=await fetch(url,{method:expected.method,headers:{Authorization:auth,'Content-Type':'application/json','X-Reel-Fixture-Phase':'prepare'},body:expected.method==='GET'?undefined:JSON.stringify(expected.body??{}),redirect:'error',signal:AbortSignal.timeout(5000)});
   assert.equal(response.status,200);c.responses.push({ok:true,data:await response.json()});
  }
 }
 const groupedURL=new URL(origin+'/jellyfin/Items/Latest?includeItemTypes=Episode');
 const groupedResponse=await fetch(groupedURL,{headers:{Authorization:'MediaBrowser Client="Reel Roku", Token="'+account.token+'"','X-Reel-Fixture-Phase':'counterfactual'},redirect:'error',signal:AbortSignal.timeout(5000)});
 assert.equal(groupedResponse.status,200);const grouped=await groupedResponse.json();assert.deepEqual(grouped.map(x=>x.Type),['Series']);assert.equal(grouped[0].ChildCount,2);
 const unsupportedSeasons=await fetch(origin+'/jellyfin/Shows/series-1/Seasons?startIndex=60&limit=60',{headers:{Authorization:'MediaBrowser Client="Reel Roku", Token="'+account.token+'"','X-Reel-Fixture-Phase':'counterfactual'},redirect:'error',signal:AbortSignal.timeout(5000)});
 assert.equal(unsupportedSeasons.status,500);const unsupportedSeasonBody=await unsupportedSeasons.json();assert.ok(unsupportedSeasonBody.error.includes('AssertionError'));
 const homeResponses=cases.find(c=>c.id==='operation-home-five-feeds').responses;
 cases.find(c=>c.id==='operation-home-partial').responses=homeResponses.map((r,i)=>i===2?{ok:false,error:'Synthetic unavailable shelf'}:r);
 cases.find(c=>c.id==='operation-home-all-failed').responses=Array.from({length:5},()=>({ok:false,error:'Synthetic network error'}));
 cases.find(c=>c.id==='operation-permission-expired').responses=[{ok:false,expired:true,error:'Synthetic permission error'}];
 cases.find(c=>c.id==='operation-invalid-page').responses=[{ok:true,data:{wrong:[]}}];
 cases.find(c=>c.id==='operation-wrong-details').responses=[{ok:true,data:{Id:'other'}}];
 const testRoot=path.join(root,'tests/interpreter-root');mkdirSync(testRoot,{recursive:true});writeFileSync(path.join(testRoot,'manifest'),'title=Reel synthetic runtime\nmajor_version=0\nminor_version=1\nbuild_version=1\n');writeFileSync(path.join(testRoot,'cases.json'),JSON.stringify(cases));
 const run=spawnSync(path.join(root,'node_modules/.bin/brs'),['-r',testRoot,path.join(root,'channel/source/Core.brs'),path.join(root,'channel/source/Format.brs'),path.join(root,'channel/source/EpisodePlayback.brs'),path.join(root,'channel/source/Operations.brs'),path.join(root,'tests/RuntimeTests.brs')],{cwd:root,encoding:'utf8',timeout:30000,maxBuffer:4*1024*1024});
 writeFileSync(path.join(root,'evidence/synthetic-stdout.log'),run.stdout??'');writeFileSync(path.join(root,'evidence/synthetic-stderr.log'),run.stderr??'');
 assert.equal(run.error,undefined);assert.equal(run.signal,null);assert.equal(run.status,0);
 const malformedReads=cases.filter(c=>{const read=c.op==='registryDecode'?c.args.read:c.storageRead;if(!read?.ok||!read.exists)return false;try{JSON.parse(read.raw);return false}catch{return true}});
 const parserLines=(run.stderr??'').trim().split('\n').filter(Boolean);
 assert.equal(parserLines.length,malformedReads.length,'Only deliberately malformed registry inputs may produce interpreter ParseJSON diagnostics');
 for(const line of parserLines)assert.ok(line==='BRIGHTSCRIPT: ERROR: ParseJSON: Data is empty'||line==="BRIGHTSCRIPT: ERROR: ParseJSON: Expected property name or '}' in JSON at position 1 (line 1 column 2)",line);

 const marker=run.stdout.indexOf('REEL_RESULTS:');assert.notEqual(marker,-1);
 function decodeTree(v){if(typeof v==='string')return decodeURIComponent(v);if(Array.isArray(v))return v.map(decodeTree);if(v&&typeof v==='object')return Object.fromEntries(Object.entries(v).map(([k,x])=>[k,decodeTree(x)]));return v}
 const results=decodeTree(JSON.parse(run.stdout.slice(marker+'REEL_RESULTS:'.length).trim()));assert.equal(results.length,cases.length);
 const passed=[];
 for(const value of results){
  try{
   expectations.get(value.id)(value.result);
   const specimen=cases.find(c=>c.id===value.id);const storage=value.storageEffects;
   assert.deepEqual(storage.map(x=>({operation:x.operation})),specimen.expectedStorage??[]);
   for(const effect of storage.filter(x=>x.operation==='write')){const saved=JSON.parse(effect.raw);assert.equal(saved.version,1);if(specimen.expectedSavedUserIds)assert.deepEqual(saved.accounts.map(a=>a.userId),specimen.expectedSavedUserIds);else assert.equal(saved.accounts[0].userId,account.userId);assert.ok(saved.accounts.every(a=>a.token===undefined&&a.password===undefined))}
   const expected=requests.get(value.id);
   if(!value.id.startsWith('operation-home-partial')&&!value.id.startsWith('operation-home-all-failed')&&!value.id.startsWith('operation-permission-expired')&&!value.id.startsWith('operation-invalid-page')&&!value.id.startsWith('operation-wrong-details')){
    assert.equal(value.effects.length,expected.length);
    for(const [i,effect] of value.effects.entries()){
      const e=expected[i];const url=new URL(effect.url);assert.equal(url.origin,'https://media.example');assert.equal(url.pathname,'/jellyfin/'+e.route);assert.equal(effect.method,e.method);
      if(e.query)assert.deepEqual(Object.fromEntries(url.searchParams),Object.fromEntries(Object.entries(e.query).map(([k,v])=>[k,String(v)])));
      if(e.body)assert.deepEqual(effect.body,e.body);if(e.bodyCheck)e.bodyCheck(effect.body);
      const token=value.id==='operation-auth'?undefined:account.token;if(token)assert.ok(effect.headers.Authorization.includes('Token="'+token+'"'));
      const fixtureURL=origin+url.pathname+url.search;
      const response=await fetch(fixtureURL,{method:effect.method,headers:{...effect.headers,'Content-Type':'application/json'},body:effect.method==='GET'?undefined:JSON.stringify(effect.body??{}),redirect:'error',signal:AbortSignal.timeout(5000)});
      assert.equal(response.status,200);assert.deepEqual(await response.json(),cases.find(c=>c.id===value.id).responses[i].data);
    }
   }
   passed.push(value.id);
  }catch(error){throw new Error(value.id+': '+error.message,{cause:error})}
 }
 const report={kind:'synthetic-BrightScript-runtime-and-owned-HTTP-fixture',passed:passed.length,failed:0,skipped:0,testIds:passed,sourcePins:Object.fromEntries(['channel/source/Core.brs','channel/source/EpisodePlayback.brs','channel/source/Operations.brs','channel/components/ReelScene.brs','channel/components/ReelScene.xml','channel/components/ApiTask.xml','tests/RuntimeTests.brs','scripts/test-runtime.mjs','tests/EpisodeSceneTests.brs','scripts/test-episode-scene.mjs','package.json','package-lock.json'].map(p=>[p,sha(p)])),interpreter:'brs 0.45.0',expectedMalformedRegistryParserDiagnostics:malformedReads.map(c=>c.id),fixtureRequests:ledger,fixtureCounts:{lifetime:ledger.length,prepare:ledger.filter(x=>x.phase==='prepare').length,effect:ledger.filter(x=>x.phase==='effect').length,counterfactual:ledger.filter(x=>x.phase==='counterfactual').length},historyFixtureReports:ledger.filter(x=>x.phase==='effect'&&x.route.startsWith('Sessions/Playing')).length,lifetimeHistoryRouteRequests:ledger.filter(x=>x.route.startsWith('Sessions/Playing')).length,defaultEpisodeGroupingCounterfactual:{passed:true,types:grouped.map(x=>x.Type),childCount:grouped[0].ChildCount},unsupportedSeasonsPaginationCounterfactual:{passed:true,httpStatus:unsupportedSeasons.status},nativeRokuOS:false,nativeHTTPAdapter:false,nativeUI:false,nativeDecoder:false,explanation:'The exact shipped Core/Operations BrightScript functions execute in the off-Roku interpreter. API responses come from a real owned ephemeral-loopback Node fixture and are replayed at the transport seam. Outgoing native-operation effects are compared exactly. This does not execute Roku networking, SceneGraph UI, registry or media decoding.'};
 assert.equal(report.historyFixtureReports,3);assert.equal(report.lifetimeHistoryRouteRequests,6);assert.equal(report.fixtureCounts.prepare,report.fixtureCounts.effect);assert.equal(report.fixtureCounts.counterfactual,2);assert.equal(ledger.filter(x=>x.responseCode===500).length,1);assert.ok(ledger.filter(x=>x.phase!=='counterfactual').every(x=>x.responseCode===200));
 await new Promise(resolve=>server.close(resolve));report.ownedFixtureStopped=!server.listening;assert.equal(report.ownedFixtureStopped,true);
 writeFileSync(path.join(root,'evidence/synthetic-results.json'),JSON.stringify(report,null,2)+'\n');
 console.log(`${passed.length} BrightScript synthetic checks passed; ${ledger.length} lifetime owned HTTP fixture requests (${report.fixtureCounts.prepare} prepare, ${report.fixtureCounts.effect} effect, 2 counterfactual); 3 effect / 6 lifetime synthetic report-route calls. No Roku OS/UI/decoder proof.`);
}finally{if(server.listening)await new Promise(resolve=>server.close(resolve))}

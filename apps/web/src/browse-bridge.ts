/** Root-approved protocol additions; frozen before host/preload IPC edits. */
export interface BrowseAccount { server: string; userId: string }
export interface BrowseScope {
  kind: 'library'|'search'|'favorites'|'music'|'photos'|'books'|'container';
  category: 'All'|'Movies'|'Series'|'Episodes'|'Collections'|'Playlists';
  libraryId: string; parentId: string; parentType: string;
}
export interface BrowseChoices {
  sort: 'SortName'|'DateCreated'|'ProductionYear'|'DateLastContentAdded';
  direction: 'Ascending'|'Descending'; genreId: string;
  watchStatus: 'Any'|'Watched'|'Unwatched'; favoritesOnly: boolean; view: 'grid'|'list';
}
export interface BrowseDocument { schema: 1; account: BrowseAccount; entries: Array<{scope: BrowseScope; choices: BrowseChoices}> }
export type BrowseRetention = 'device'|'session';
/** Opaque host byte-CAS: absent or sha256:<64 lowercase hex>. Never a path. */
export type BrowseRevision = string;
export type BrowseCode = 'invalid'|'stale'|'closing'|'conflict'|'unavailable'|'io'|'preserved'|'limit'|'uncertain'|'corrupt'|'unsupported';
export interface BrowseCleanupNotice { id: string; accountId: string; count: number; code: 'preserved'|'io'|'uncertain' }
export type BrowseOpenResult =
  | {ok:true; lease:string; retention:BrowseRetention; revision:BrowseRevision; document:BrowseDocument; notices:BrowseCleanupNotice[]}
  | {ok:false; code:'corrupt'|'unsupported'; lease:string; retention:'device'; revision:BrowseRevision; canReset:true; notices:BrowseCleanupNotice[]}
  | {ok:false; code:BrowseCode; canReset:false; notices:BrowseCleanupNotice[]};
export type BrowseWriteResult = {ok:true; revision:BrowseRevision}|{ok:false; code:BrowseCode};
export interface ReelBrowsePreferences {
  open(value:{account:BrowseAccount; generation:number}):Promise<BrowseOpenResult>;
  commit(value:{lease:string; expectedRevision:BrowseRevision; document:BrowseDocument}):Promise<BrowseWriteResult>;
  reset(value:{lease:string; expectedRevision:BrowseRevision}):Promise<BrowseWriteResult>;
  revoke(value:{generation:number}):Promise<{ok:true}|{ok:false;code:BrowseCode}>;
  /** At most one disposable subscriber; initial bounded notices are delivered too. */
  onCleanupNotice(callback:(notice:BrowseCleanupNotice)=>void):()=>void;
}

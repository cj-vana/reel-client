import type { Account } from './types.ts';
import type { ConnectionPersistence, ConnectionSnapshot, StorageLike } from './storage.ts';
export type DesktopCode = 'conflict' | 'locked' | 'corrupt' | 'unavailable' | 'invalid' | 'io' | 'closing' | 'uncertain';
export type DesktopResult<T extends object = object> = ({ ok: true } & T) | { ok: false; code: DesktopCode };
export type DesktopInitialization = DesktopResult<{
  storeState: 'ready' | 'locked' | 'corrupt' | 'unavailable'; revision?: number; savedConnections?: ConnectionSnapshot;
  deviceId: string; preferences: { quality: number; history: boolean; autoplay?: boolean; markers?: boolean; autoSkip?: boolean; updates?: boolean }; preferenceRevision: number;
}>;
export interface DesktopBridge {
  initialize(): Promise<DesktopInitialization>;
  saveConnections(value: ConnectionSnapshot & { expectedRevision: number }): Promise<DesktopResult<{ revision: number }>>;
  savePreferences(value: { quality: number; history: boolean; autoplay?: boolean; markers?: boolean; autoSkip?: boolean; updates?: boolean; expectedRevision: number }): Promise<DesktopResult<{ revision: number }>>;
  onCloseRequested(callback: (nonce: string) => void): () => void;
  acknowledgeClose(nonce: string): Promise<DesktopResult>;
}
declare global { interface Window { ReelDesktop?: DesktopBridge } }
export function desktopBridge(value: unknown, required = false): DesktopBridge | undefined {
  if (value === undefined && !required) return;
  const methods = ['initialize', 'saveConnections', 'savePreferences', 'onCloseRequested', 'acknowledgeClose'];
  if (!value || typeof value !== 'object' || !methods.every(method => typeof (value as Record<string, unknown>)[method] === 'function')) throw new Error('The desktop secure connection interface could not start. Reopen Reel to try again.');
  return value as DesktopBridge;
}
const messages: Record<DesktopCode, string> = {
  conflict: 'Saved settings changed in another app window. Reopen Reel before changing them again.',
  locked: 'Your secure connections could not be unlocked. They remain saved. You can use a session-only connection.',
  corrupt: 'Your saved connections could not be read safely. They have not been changed. You can use a session-only connection.',
  unavailable: 'Secure storage is unavailable on this system. Connections can be used for this session only. Quit and reopen Reel to retry secure storage.',
  invalid: 'This connection could not be saved safely. Check the server address and try again.',
  io: 'Reel could not save this change. Your previous saved settings are intact. Check device storage and try again.',
  closing: 'Reel is closing. Reopen it to continue.',
  uncertain: 'Reel could not confirm that this change was fully saved. The saved state may have changed, and sign-out may be unfinished. Quit and reopen Reel to reload it before making more changes.'
};
export class DesktopPersistenceError extends Error {
  readonly code: DesktopCode;
  constructor(code: DesktopCode) { super(messages[code]); this.code = code; }
}
export function desktopError(code: DesktopCode): DesktopPersistenceError { return new DesktopPersistenceError(code); }
export function uncertainDesktopError(error: unknown): boolean { return error instanceof DesktopPersistenceError && error.code === 'uncertain'; }
export function memoryStorage(seed: Record<string, string> = {}): StorageLike {
  const values = new Map(Object.entries(seed));
  return { getItem: key => values.get(key) ?? null, setItem: (key, value) => { values.set(key, value); }, removeItem: key => { values.delete(key); } };
}
export class DesktopSession {
  readonly storage: StorageLike;
  readonly persistence: ConnectionPersistence;
  private available: boolean;
  get canRemember(): boolean { return this.available && !this.requiresReopen; }
  requiresReopen = false;
  readonly storageMessage: string;
  private preferenceRevision: number;
  private preferenceQueue: Promise<void> = Promise.resolve();
  private closed = false;
  private bridge: DesktopBridge;
  constructor(bridge: DesktopBridge, initial: Extract<DesktopInitialization, { ok: true }>) {
    this.bridge = bridge;
    this.available = initial.storeState === 'ready' && initial.revision !== undefined && initial.savedConnections !== undefined;
    this.storageMessage = this.canRemember ? 'Remembered connections use your operating system’s encrypted storage. Your password is never saved. Leave this off on shared devices.' : messages[initial.storeState === 'ready' ? 'unavailable' : initial.storeState];
    this.preferenceRevision = initial.preferenceRevision;
    this.storage = memoryStorage({ 'reel.device.v1': initial.deviceId, 'reel.quality': String(initial.preferences.quality), 'reel.history': String(initial.preferences.history), 'reel.autoplay': String(initial.preferences.autoplay ?? true), 'reel.markers': String(initial.preferences.markers ?? true), 'reel.autoskip': String(initial.preferences.autoSkip ?? false), 'reel.updates': String(initial.preferences.updates ?? true) });
    let revision = initial.revision ?? 0;
    let savedAccounts = JSON.stringify(initial.savedConnections?.accounts ?? []);
    this.persistence = {
      snapshot: this.canRemember ? initial.savedConnections! : { accounts: [], activeId: null },
      save: async snapshot => {
        if (this.requiresReopen) throw desktopError('uncertain');
        if (this.closed) throw desktopError('closing');
        if (!this.canRemember) {
          if (snapshot.accounts.length) throw desktopError('unavailable');
          return;
        }
        // A session-only choice does not rewrite or merge the encrypted vault. Previously
        // remembered connections keep their durable selection for the next cold launch.
        if (snapshot.activeId === null && JSON.stringify(snapshot.accounts) === savedAccounts) return;
        const result = await bridge.saveConnections({ ...snapshot, expectedRevision: revision });
        if (!result.ok) { if (result.code === 'uncertain') this.requiresReopen = true; throw desktopError(result.code); }
        revision = result.revision; savedAccounts = JSON.stringify(snapshot.accounts);
      }
    };
  }
  savePreferences(quality: number, history: boolean, autoplay = true, markers = true, autoSkip = false, updates = true): Promise<void> {
    if (this.requiresReopen) return Promise.reject(desktopError('uncertain'));
    if (this.closed) return Promise.reject(desktopError('closing'));
    const operation = this.preferenceQueue.then(async () => {
      if (this.requiresReopen) throw desktopError('uncertain');
      const result = await this.bridge.savePreferences({ quality, history, autoplay, markers, autoSkip, updates, expectedRevision: this.preferenceRevision });
      if (!result.ok) { if (result.code === 'uncertain') this.requiresReopen = true; throw desktopError(result.code); }
      this.preferenceRevision = result.revision;
    });
    this.preferenceQueue = operation.catch(() => undefined);
    return operation;
  }
  close(): void { this.closed = true; }
  drain(): Promise<void> { return this.preferenceQueue; }
}
export function desktopAccount(account: Account, canRemember: boolean): Account { return canRemember ? account : { ...account, remember: false }; }
export class DesktopLifecycle {
  closing = false;
  private cleanup?: () => Promise<unknown>;
  private draining?: Promise<void>;
  constructor(bridge: DesktopBridge, timeoutMs = 5500) {
    // Register before initialize() is awaited. A close during locked-store boot must fence
    // the eventual initialization result without ever starting account/API/navigation work.
    bridge.onCloseRequested(nonce => {
      this.closing = true;
      if (!this.draining) {
        let timer: ReturnType<typeof setTimeout>;
        this.draining = Promise.race([Promise.resolve().then(() => this.cleanup?.()).then(() => undefined), new Promise<void>(resolve => { timer = setTimeout(resolve, timeoutMs); })]).catch(() => undefined).finally(() => clearTimeout(timer));
      }
      void this.draining.then(() => bridge.acknowledgeClose(nonce)).catch(() => undefined);
    });
  }
  setDrain(cleanup: () => Promise<unknown>): void { this.cleanup = cleanup; }
}

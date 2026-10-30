import { normalizeServer } from './api.ts';
import type { Account } from './types.ts';

/** Logout revokes the token, including every saved URL alias that still uses it. */
export function hasSessionReference(account: Account, remaining: readonly Account[]): boolean {
  try {
    const server = normalizeServer(account.server);
    return remaining.some(value => value.token === account.token && normalizeServer(value.server) === server);
  } catch { return true; } // An unknown identity is preserved, never revoked by guesswork.
}

export async function revokeUnusedSession(account: Account, remaining: () => readonly Account[], revoke: (account: Account) => Promise<void>): Promise<void> {
  if (!hasSessionReference(account, remaining())) await revoke(account);
}

/** The UI's committed removal boundary; failed persistence never reaches server revocation. */
export async function removeConnectionAndRevoke(options: {
  account?: Account;
  remove: () => void | Promise<void>;
  remaining: () => readonly Account[];
  afterRemove: (account: Account) => Promise<void>;
  revoke: (account: Account) => Promise<void>;
}): Promise<void> {
  await options.remove();
  if (!options.account) return;
  await options.afterRemove(options.account);
  // Recheck after async local cleanup: a retained or newly reauthenticated alias may own this token.
  await revokeUnusedSession(options.account, options.remaining, options.revoke);
}

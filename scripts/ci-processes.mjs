import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';

export async function assertPortFree(port) {
  const server = createServer();
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen({ port, host: '127.0.0.1', exclusive: true }, resolve); });
  await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
}

export function ownsListener(child, port) {
  if (child.exitCode !== null || child.signalCode !== null) throw new Error('Owned child exited before readiness');
  let pids;
  try { pids = execFileSync('lsof', ['-nP', '-a', '-iTCP:' + port, '-sTCP:LISTEN', '-t'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim().split(/\s+/).filter(Boolean).map(Number); }
  catch (error) { if (error.status === 1) return false; throw error; }
  if (pids.some(pid => pid !== child.pid)) throw new Error('Loopback listener is not the owned child');
  return pids.includes(child.pid);
}

export function spawnOwned(command, args, options = {}) {
  const child = spawn(command, args, { detached: true, stdio: 'inherit', ...options });
  // Install immediately: a failed executable must never become an unhandled error.
  child.spawnError = null;
  child.on('error', error => { child.spawnError = error; });
  return child;
}

export async function exited(child) {
  if (child.spawnError) throw child.spawnError;
  if (child.exitCode !== null || child.signalCode !== null) return child.exitCode ?? 1;
  return new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', code => resolve(code ?? 1)); });
}

export async function stopOwned(child, timeoutMs = 3000) {
  if (!child.pid) return;
  const alive = () => { try { process.kill(-child.pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } };
  for (const [signal, timeout] of [['SIGTERM', timeoutMs], ['SIGKILL', 2000]]) {
    if (!alive()) return;
    process.kill(-child.pid, signal);
    const deadline = Date.now() + timeout;
    while (alive() && Date.now() < deadline) await delay(25);
  }
  if (alive()) throw new Error('Owned process group did not exit');
}

export async function ready(child, port, path, verify, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.spawnError) throw child.spawnError;
    if (ownsListener(child, port)) {
      try {
        const response = await fetch('http://127.0.0.1:' + port + path, { signal: AbortSignal.timeout(1000) });
        if (response.ok && await verify(response)) return;
      } catch { /* Retry only this owned listener until the bounded deadline. */ }
    }
    await delay(100);
  }
  throw new Error('Owned loopback service did not become ready: ' + port);
}

export async function supervise(action) {
  const children = [];
  const start = (command, args, options) => { const child = spawnOwned(command, args, options); children.push(child); return child; };
  let interrupted = false;
  const interrupt = () => { interrupted = true; for (const child of children) if (child.pid) { try { process.kill(-child.pid, 'SIGTERM'); } catch (error) { if (error.code !== 'ESRCH') console.error(error.message); } } };
  process.once('SIGINT', interrupt); process.once('SIGTERM', interrupt);
  try { const result = await action(start); if (interrupted) throw new Error('CI operation interrupted'); return result; }
  finally {
    const cleanup = await Promise.allSettled(children.map(child => stopOwned(child)));
    process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', interrupt);
    const failed = cleanup.find(result => result.status === 'rejected');
    if (failed) throw failed.reason;
  }
}

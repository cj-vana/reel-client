import { createServer } from 'node:net';
import { execFileSync } from 'node:child_process';
export async function assertPortFree(port) {
  const server = createServer();
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen({ port, host: '127.0.0.1', exclusive: true }, resolve); });
  await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
}
export function ownsListener(child, port) {
  if (child.exitCode !== null || child.signalCode !== null) throw new Error('Owned process exited before readiness');
  let ids;
  try { ids = execFileSync('/usr/sbin/lsof', ['-nP', '-a', '-iTCP:' + port, '-sTCP:LISTEN', '-t'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim().split(/\s+/).filter(Boolean).map(Number); }
  catch (error) { if (error.status === 1) return false; throw error; }
  if (ids.some(pid => pid !== child.pid)) throw new Error('The loopback port belongs to another process');
  return ids.includes(child.pid);
}
export async function waitForExit(child, timeoutMs) {
  if (child.exitCode !== null || child.signalCode !== null) return true;
  return new Promise(resolve => {
    const finish = result => { clearTimeout(timer); child.removeListener('exit', exited); resolve(result); };
    const exited = () => finish(true), timer = setTimeout(() => finish(false), timeoutMs);
    child.once('exit', exited);
    if (child.exitCode !== null || child.signalCode !== null) finish(true);
  });
}
export async function stopOwnedChild(child, timeoutMs = 4000) {
  if (child.exitCode !== null || child.signalCode !== null) return true;
  child.kill('SIGTERM');
  if (await waitForExit(child, timeoutMs)) return true;
  child.kill('SIGKILL');
  return waitForExit(child, 2000);
}

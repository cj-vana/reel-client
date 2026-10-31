// The pieces of a self-update that need no code-signing certificate. Each release attaches a manifest naming the
// ZIP for every platform with its SHA-256 and size. The release workflow signs the manifest with an Ed25519 key and
// the app carries the public half, so nothing from a release is used until the signature and the digest both match.
import { createHash, createPublicKey, verify } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { access, constants, lstat, mkdir, open, rename, rm, symlink } from 'node:fs/promises';
import { dirname, join, posix, relative, resolve, win32 } from 'node:path';
import { Readable, Transform, Writable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { createInflateRaw, crc32 } from 'node:zlib';

export const REPOSITORY = 'cj-vana/reel-client';
export const RELEASES = `https://github.com/${REPOSITORY}/releases`;
export const MANIFEST = 'reel-desktop-update.json';
export const SIGNATURE = MANIFEST + '.sig';
// Platform and architecture, as Node reports them, to the label in the release file names.
export const TARGETS = Object.freeze({ 'darwin-arm64': 'macos-arm64', 'linux-x64': 'linux-x64', 'win32-x64': 'windows-x64' });
const MAX_PACKAGE = 1024 ** 3, MAX_UNPACKED = 3 * 1024 ** 3, MAX_ENTRIES = 50_000, MAX_SMALL = 64 * 1024;

export class UpdateError extends Error {
  /** code: what failed, for the state the app reports: manifest, signature, download, package or install. */
  constructor(code, cause) { super('Update ' + code + ' failed', cause ? { cause } : undefined); this.name = 'UpdateError'; this.code = code; }
}

/** Where a release keeps its files: the newest published release's manifest, and one tag's assets. */
export function releaseURLs(base = RELEASES) {
  const root = String(base).replace(/\/+$/, '');
  return {
    manifest: `${root}/latest/download/${MANIFEST}`,
    signature: `${root}/latest/download/${SIGNATURE}`,
    asset: (tag, name) => `${root}/download/${encodeURIComponent(tag)}/${encodeURIComponent(name)}`
  };
}

/** Compares MAJOR.MINOR.PATCH versions, with or without a leading v. A pre-release suffix sorts first. */
export function compareVersions(a, b) {
  const parse = value => {
    const match = /^v?(\d+)\.(\d+)\.(\d+)(-.+)?$/.exec(String(value));
    return match ? [Number(match[1]), Number(match[2]), Number(match[3]), match[4] ? 0 : 1] : undefined;
  };
  const left = parse(a), right = parse(b);
  if (!left || !right) return NaN;
  for (let index = 0; index < 4; index++) if (left[index] !== right[index]) return left[index] < right[index] ? -1 : 1;
  return 0;
}

/**
 * Checks the manifest's signature with `publicKey` (base64 SPKI DER), then its contents. Returns the release version,
 * its tag and the file for `target`, or throws an UpdateError. The signature covers the exact bytes served.
 */
export function readManifest(bytes, signature, publicKey, target) {
  let key;
  try { key = createPublicKey({ key: Buffer.from(publicKey, 'base64'), format: 'der', type: 'spki' }); }
  catch (error) { throw new UpdateError('signature', error); }
  const text = String(signature ?? '').trim();
  if (key.asymmetricKeyType !== 'ed25519' || !/^[A-Za-z0-9+/]{86}==$/.test(text)) throw new UpdateError('signature');
  if (!verify(null, Buffer.from(bytes), key, Buffer.from(text, 'base64'))) throw new UpdateError('signature');
  let manifest;
  try { manifest = JSON.parse(Buffer.from(bytes).toString('utf8')); } catch (error) { throw new UpdateError('manifest', error); }
  const version = manifest?.version, file = manifest?.files?.[target];
  const valid = manifest && typeof manifest === 'object' && manifest.schema === 1 && manifest.product === 'reel-desktop' &&
    manifest.repository === REPOSITORY && typeof version === 'string' && /^\d+\.\d+\.\d+$/.test(version) && manifest.tag === 'v' + version &&
    Object.hasOwn(TARGETS, target) && file && typeof file === 'object' && file.name === `reel-desktop-${TARGETS[target]}-v${version}.zip` &&
    typeof file.sha256 === 'string' && /^[a-f0-9]{64}$/.test(file.sha256) && Number.isSafeInteger(file.size) && file.size > 0 && file.size <= MAX_PACKAGE;
  if (!valid) throw new UpdateError('manifest');
  return { version, tag: manifest.tag, file: { name: file.name, sha256: file.sha256, size: file.size } };
}

/** Reads a small response body, refusing anything larger than `limit` bytes. */
export async function readSmall(fetch, url, { signal, limit = MAX_SMALL } = {}) {
  let response;
  try { response = await fetch(url, { signal }); } catch (error) { throw new UpdateError('manifest', error); }
  if (response.status === 404) return null;
  if (!response.ok || !response.body) throw new UpdateError('manifest');
  const chunks = []; let size = 0;
  for await (const chunk of response.body) {
    size += chunk.byteLength;
    if (size > limit) throw new UpdateError('manifest');
    chunks.push(Buffer.from(chunk));
  }
  return Buffer.concat(chunks);
}

/** Downloads to `path`, checking size while it streams and the SHA-256 at the end. A mismatch leaves no file. */
export async function downloadFile(fetch, url, path, { sha256, size }, { signal, onProgress } = {}) {
  const partial = path + '.part';
  await rm(partial, { force: true });
  try {
    const response = await fetch(url, { signal });
    if (!response.ok || !response.body) throw new UpdateError('download');
    const hash = createHash('sha256');
    let received = 0;
    const meter = new Transform({
      transform(chunk, _encoding, done) {
        received += chunk.length;
        if (received > size) { done(new UpdateError('download')); return; }
        hash.update(chunk); onProgress?.(received / size); done(null, chunk);
      }
    });
    await pipeline(Readable.fromWeb(response.body), meter, createWriteStream(partial, { flags: 'wx', mode: 0o600 }), ...(signal ? [{ signal }] : []));
    if (received !== size || hash.digest('hex') !== sha256) throw new UpdateError('download');
    await rename(partial, path);
  } catch (error) {
    await rm(partial, { force: true });
    if (signal?.aborted) throw error;
    throw error instanceof UpdateError ? error : new UpdateError('download', error);
  }
}

const u16 = (buffer, at) => buffer.readUInt16LE(at), u32 = (buffer, at) => buffer.readUInt32LE(at);
const u64 = (buffer, at) => { const value = buffer.readBigUInt64LE(at); if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw new UpdateError('package'); return Number(value); };

async function readAt(handle, position, length) {
  const buffer = Buffer.alloc(length);
  const { bytesRead } = await handle.read(buffer, 0, length, position);
  if (bytesRead !== length) throw new UpdateError('package');
  return buffer;
}

/** The central directory of a ZIP: name, method, sizes, CRC, local header offset and Unix mode of every entry. */
async function zipEntries(handle) {
  const { size } = await handle.stat();
  const tailLength = Math.min(size, 65_557), tail = await readAt(handle, size - tailLength, tailLength);
  let end = -1;
  for (let at = tailLength - 22; at >= 0; at--) if (u32(tail, at) === 0x06054b50) { end = at; break; }
  if (end < 0) throw new UpdateError('package');
  let count = u16(tail, end + 10), directorySize = u32(tail, end + 12), directoryOffset = u32(tail, end + 16);
  if (count === 0xffff || directorySize === 0xffffffff || directoryOffset === 0xffffffff) {
    const locatorAt = size - tailLength + end - 20, locator = await readAt(handle, locatorAt, 20);
    if (u32(locator, 0) !== 0x07064b50) throw new UpdateError('package');
    const record = await readAt(handle, u64(locator, 8), 56);
    if (u32(record, 0) !== 0x06064b50) throw new UpdateError('package');
    count = u64(record, 32); directorySize = u64(record, 40); directoryOffset = u64(record, 48);
  }
  if (count > MAX_ENTRIES || directorySize > 64 * 1024 * 1024 || directoryOffset + directorySize > size) throw new UpdateError('package');
  const directory = await readAt(handle, directoryOffset, directorySize), entries = [];
  for (let at = 0, index = 0; index < count; index++) {
    if (at + 46 > directory.length || u32(directory, at) !== 0x02014b50) throw new UpdateError('package');
    const madeBy = u16(directory, at + 4), flags = u16(directory, at + 8), method = u16(directory, at + 10), crc = u32(directory, at + 16);
    let compressed = u32(directory, at + 20), uncompressed = u32(directory, at + 24);
    const nameLength = u16(directory, at + 28), extraLength = u16(directory, at + 30), commentLength = u16(directory, at + 32);
    const external = u32(directory, at + 38);
    let offset = u32(directory, at + 42);
    const name = directory.subarray(at + 46, at + 46 + nameLength).toString(flags & 0x800 ? 'utf8' : 'latin1');
    // ZIP64 sizes and offsets live in extra field 1, in this order, only for the fields that overflowed.
    for (let extra = at + 46 + nameLength, stop = extra + extraLength; extra + 4 <= stop;) {
      const id = u16(directory, extra), length = u16(directory, extra + 2);
      if (id === 1) {
        let field = extra + 4;
        if (uncompressed === 0xffffffff) { uncompressed = u64(directory, field); field += 8; }
        if (compressed === 0xffffffff) { compressed = u64(directory, field); field += 8; }
        if (offset === 0xffffffff) { offset = u64(directory, field); field += 8; }
      }
      extra += 4 + length;
    }
    if (flags & 0x1 || ![0, 8].includes(method)) throw new UpdateError('package');
    const unix = madeBy >> 8 === 3 ? external >>> 16 : 0;
    const type = unix & 0o170000;
    const kind = type === 0o120000 ? 'link' : type === 0o040000 || name.endsWith('/') || (!unix && external & 0x10) ? 'directory' : 'file';
    entries.push({ name, method, crc, compressed, uncompressed, offset, mode: unix & 0o777, kind });
    at += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

/** Splits an entry name into safe path segments, or throws: no absolute paths, drive letters, `.` or `..`. */
function segments(name) {
  const parts = name.replace(/\/+$/, '').split('/');
  if (!name || name.includes('\\') || name.includes('\0') || name.startsWith('/') || /^[A-Za-z]:/.test(name) ||
    parts.some(part => !part || part === '.' || part === '..')) throw new UpdateError('package');
  return parts;
}

async function entryStream(handle, entry) {
  const header = await readAt(handle, entry.offset, 30);
  if (u32(header, 0) !== 0x04034b50) throw new UpdateError('package');
  const start = entry.offset + 30 + u16(header, 26) + u16(header, 28);
  const raw = createReadStream(null, { fd: handle.fd, autoClose: false, start, end: start + entry.compressed - 1 });
  return entry.method === 8 ? raw.pipe(createInflateRaw()) : raw;
}

/**
 * Unpacks a release ZIP into `destination`, which must not exist yet. Every entry must sit under the folder `top`.
 * Sizes and CRCs are checked, Unix modes are kept, and links may only point inside the package; they are made last
 * so nothing is ever written through one.
 */
export async function extractZip(file, destination, top) {
  const handle = await open(file, 'r');
  try {
    const entries = await zipEntries(handle), seen = new Set(), links = [];
    let unpacked = 0;
    await mkdir(destination, { recursive: false, mode: 0o755 });
    const root = resolve(destination);
    const parsed = entries.map(entry => ({ ...entry, parts: segments(entry.name) }));
    for (const entry of parsed) {
      const key = entry.parts.join('/');
      if (entry.parts[0] !== top || seen.has(key)) throw new UpdateError('package');
      seen.add(key);
      if (entry.kind === 'link') links.push(entry);
    }
    // Nothing may be written below a path that is a link in the package.
    const linkPaths = new Set(links.map(entry => entry.parts.join('/')));
    for (const entry of parsed) for (let depth = 1; depth < entry.parts.length; depth++) if (linkPaths.has(entry.parts.slice(0, depth).join('/'))) throw new UpdateError('package');
    for (const entry of parsed) {
      const target = join(root, ...entry.parts);
      if (entry.kind === 'directory') { await mkdir(target, { recursive: true, mode: 0o755 }); continue; }
      if (entry.kind === 'link') continue;
      unpacked += entry.uncompressed;
      if (unpacked > MAX_UNPACKED) throw new UpdateError('package');
      await mkdir(dirname(target), { recursive: true, mode: 0o755 });
      let size = 0, checksum = 0;
      const check = new Transform({
        transform(chunk, _encoding, done) {
          size += chunk.length;
          if (size > entry.uncompressed) { done(new UpdateError('package')); return; }
          checksum = crc32(chunk, checksum); done(null, chunk);
        }
      });
      await pipeline(await entryStream(handle, entry), check, createWriteStream(target, { flags: 'wx', mode: entry.mode || 0o644 }));
      if (size !== entry.uncompressed || checksum >>> 0 !== entry.crc) throw new UpdateError('package');
    }
    for (const entry of links) {
      if (entry.uncompressed > 4096) throw new UpdateError('package');
      const chunks = [];
      await pipeline(await entryStream(handle, entry), new Writable({ write(chunk, _encoding, done) { chunks.push(chunk); done(); } }));
      const pointsTo = Buffer.concat(chunks).toString('utf8'), at = join(root, ...entry.parts);
      const landing = resolve(dirname(at), pointsTo), inside = relative(join(root, top), landing);
      if (!pointsTo || pointsTo.startsWith('/') || inside.startsWith('..') || resolve(join(root, top), inside) !== landing) throw new UpdateError('package');
      await mkdir(dirname(at), { recursive: true, mode: 0o755 });
      await symlink(pointsTo, at);
    }
    const info = await lstat(join(root, top));
    if (!info.isDirectory()) throw new UpdateError('package');
  } catch (error) {
    await rm(destination, { recursive: true, force: true });
    throw error instanceof UpdateError ? error : new UpdateError('package', error);
  } finally { await handle.close(); }
}

/**
 * Where this copy of Reel lives and whether it can replace itself there. `name` is the packaged app name ("Reel").
 * macOS: the .app bundle, in an Applications folder and outside App Translocation. Windows and Linux: the folder
 * holding the executable. Returns { ok: true, folder, parent, top, target } or { ok: false, reason } with reason
 * platform, location, translocated, permission or sandbox.
 */
export async function installLocation({ platform, arch, execPath, name, inApplications = true, writable = canWrite, info = lstat }) {
  const target = platform + '-' + arch, path = platform === 'win32' ? win32 : posix;
  if (!Object.hasOwn(TARGETS, target)) return { ok: false, reason: 'platform' };
  let folder, top;
  if (platform === 'darwin') {
    const bundle = path.resolve(execPath, '..', '..', '..');
    if (!bundle.endsWith('.app') || path.resolve(bundle, 'Contents', 'MacOS') !== path.dirname(path.resolve(execPath))) return { ok: false, reason: 'location' };
    if (bundle.split(path.sep).includes('AppTranslocation')) return { ok: false, reason: 'translocated' };
    // A copy run from a disk image or a download folder is left as it is.
    if (!inApplications) return { ok: false, reason: 'location' };
    folder = bundle; top = name + '.app';
  } else { folder = path.dirname(path.resolve(execPath)); top = `${name}-${target}`; }
  const parent = path.dirname(folder);
  if (parent === folder || !(await writable(parent)) || !(await writable(folder))) return { ok: false, reason: 'permission' };
  if (platform === 'linux') {
    // A sandbox helper made setuid root needs root to set up again, so a fresh copy would not start.
    try {
      const sandbox = await info(path.join(folder, 'chrome-sandbox'));
      if (sandbox.uid === 0 && (sandbox.mode & 0o4000)) return { ok: false, reason: 'sandbox' };
    } catch { /* No sandbox helper: nothing to keep. */ }
  }
  return { ok: true, folder, parent, top, target };
}

async function canWrite(path) {
  try { await access(path, constants.W_OK); return true; } catch { return false; }
}

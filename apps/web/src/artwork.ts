import { type ArtworkShape, JellyfinAPI } from './api.ts';
import { type MediaItem } from './types.ts';

export class ArtworkCache {
  private images = new Map<string, { url: string; bytes: number }>();
  private pending = new Map<string, { promise: Promise<string>; controller: AbortController }>();
  private generation = 0;
  private bytes = 0;
  private readonly maxEntries: number;
  private readonly maxBytes: number;
  constructor(maxEntries = 120, maxBytes = 32 * 1024 * 1024) { this.maxEntries = maxEntries; this.maxBytes = maxBytes; }
  cancelPending(): void {
    this.generation++;
    this.pending.forEach(load => load.controller.abort());
    this.pending.clear();
  }
  clear(): void {
    this.cancelPending();
    this.images.forEach(image => URL.revokeObjectURL(image.url));
    this.images.clear(); this.bytes = 0;
  }
  async get(api: JellyfinAPI, item: MediaItem, shape: ArtworkShape = 'poster', width = 600): Promise<string> {
    const key = (api.account?.id ?? '') + '|' + api.imageURL(item, shape, width).toString();
    const hit = this.images.get(key);
    if (hit) { this.images.delete(key); this.images.set(key, hit); return hit.url; }
    const inFlight = this.pending.get(key);
    if (inFlight) return inFlight.promise;
    const generation = this.generation, controller = new AbortController();
    const load = api.image(item, shape, width, controller.signal).then(blob => {
      if (generation !== this.generation) throw new DOMException('Cancelled', 'AbortError');
      if (blob.size > this.maxBytes) throw new Error('Artwork exceeds the memory budget.');
      const url = URL.createObjectURL(blob);
      this.images.set(key, { url, bytes: blob.size }); this.bytes += blob.size;
      while (this.images.size > this.maxEntries || this.bytes > this.maxBytes) {
        const oldest = this.images.keys().next().value as string;
        const image = this.images.get(oldest)!;
        URL.revokeObjectURL(image.url); this.bytes -= image.bytes; this.images.delete(oldest);
      }
      return url;
    }).finally(() => { if (generation === this.generation) this.pending.delete(key); });
    this.pending.set(key, { promise: load, controller }); return load;
  }
  observe(root: HTMLElement, api: JellyfinAPI, items: Map<string, MediaItem>): () => void {
    const observer = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if (!entry.isIntersecting) return;
        const image = entry.target as HTMLImageElement;
        observer.unobserve(image);
        const item = items.get(image.dataset.art ?? '');
        if (!item) return;
        // A blob URL evicted before decoding fails here; show the placeholder rather than a broken image.
        image.addEventListener('error', () => { image.classList.remove('loaded'); image.classList.add('unavailable'); }, { once: true });
        this.get(api, item, (image.dataset.shape ?? 'poster') as ArtworkShape, Number(image.dataset.width ?? 500)).then(url => { if (image.isConnected) { image.src = url; image.classList.add('loaded'); } }).catch(() => image.classList.add('unavailable'));
      });
    }, { rootMargin: '400px' });
    root.querySelectorAll('img[data-art]').forEach(image => observer.observe(image));
    return () => observer.disconnect();
  }
}

export class CloseGate {
  constructor({ request, finish, timeoutMs = 6500, schedule = setTimeout, cancel = clearTimeout }) {
    this.request = request; this.finish = finish; this.timeoutMs = timeoutMs; this.schedule = schedule; this.cancel = cancel;
  }
  pending = false;
  begin() {
    if (this.pending) return;
    this.pending = true;
    this.timer = this.schedule(() => this.complete(), this.timeoutMs);
    Promise.resolve().then(() => this.request()).then(() => this.complete(), () => this.complete());
  }
  complete() {
    if (!this.pending) return;
    this.pending = false; this.cancel(this.timer); this.timer = undefined;
    this.finish();
  }
}

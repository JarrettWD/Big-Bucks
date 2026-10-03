// The last kid who signed in on this device, so day to day she only types her
// PIN. Only the username and the name the app calls her are kept, never the PIN.
// Browser storage can be missing or blocked, so every read and write is guarded.

const KEY = 'bb.lastKid';

export interface RememberedKid {
  username: string;
  displayName?: string;
}

export function getRememberedKid(): RememberedKid | null {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return null;
    const v = JSON.parse(raw) as RememberedKid;
    return typeof v?.username === 'string' && v.username ? v : null;
  } catch {
    return null;
  }
}

export function rememberKid(kid: RememberedKid): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(kid));
  } catch {
    /* storage blocked: she'll just type her username next time */
  }
}

export function forgetKid(): void {
  try {
    localStorage.removeItem(KEY);
  } catch {
    /* nothing to do */
  }
}

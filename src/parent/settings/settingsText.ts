// The Settings screen's words, for Dad. What the girls see comes from the
// database's notices, previewed word for word (docs/MESSAGES.md §1).

export interface ExpirySettings {
  days: number;
  min: number;
  max: number;
  scheduled: { days: number; from: string }[];
  history: { days: number; from: string; note: string | null; who: string; when: string | null }[];
}
export interface SettingsData {
  today: string;
  today_text: string;
  expiry: ExpirySettings;
}
export interface ChangePreview {
  problem: string | null;
  notices: { title: string; body: string; kids: number }[];
  notices_on: string | null;
  summary: string | null;
}

/** Whole days typed by Dad, or a message. The database checks again. */
export function parseDays(text: string, min: number, max: number): number | string {
  const t = text.trim();
  if (t === '') return `Type a number of days from ${min} to ${max}.`;
  if (!/^\d{1,2}$/.test(t) || t.startsWith('0')) return `Use whole days, from ${min} to ${max}.`;
  const n = Number(t);
  if (n < min || n > max) return `Use whole days, from ${min} to ${max}.`;
  return n;
}

export const TEXT = {
  title: 'Settings',
  expiryTitle: 'Time to answer a request',
  expiryNow: (days: number) => `${days} days`,
  expiryExplain:
    "When she asks to put money in or take it out, you have this long to say yes or no. If you don't, the request is cancelled and any money on hold is freed. Each request keeps the time it had when she asked.",
  scheduled: (days: number, from: string) => `From ${from}: ${days} days`,
  change: 'Change',
  changeHeading: 'Change how long you have to answer?',
  willRecord: 'This will be recorded:',
  daysLabel: (min: number, max: number) => `Days to answer (${min} to ${max})`,
  startsLabel: 'Starts on',
  noteLabel: 'Note for your records (optional; the girls don’t see it)',
  theySee: (on: string | null, kids: number) =>
    on
      ? `On ${on}, ${kids === 1 ? 'she' : `every kid (${kids} accounts)`} will see:`
      : `${kids === 1 ? 'She' : `Every kid (${kids} accounts)`} will see this right away:`,
  noNotice: "The girls won't get a notice: the number isn't changing.",
  checking: 'Checking…',
  yes: (days: number) => `Yes, change to ${days} days`,
  back: 'Back',
  saving: 'Saving…',
  done: (summary: string, who: string, when: string) =>
    `Done. ${summary} Recorded: ${who}, ${when}.`,
  history: 'History',
  historyLine: (h: { days: number; from: string }) => `${h.days} days from ${h.from}`,
  historyWho: (h: { who: string; when: string | null }) => (h.when ? `${h.who}, ${h.when}` : h.who),
  more: 'Rates, the deposit cap, inflation, dividend yields, feature switches, wording and Download backup arrive in the next part of stage 8.',
  loadError: (e: string) => `Couldn't load Settings: ${e}`,
  retry: 'Try again',
};

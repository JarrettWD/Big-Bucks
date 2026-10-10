// The Settings screen's words, for Dad. What the girls see comes from the
// database's notices, previewed word for word (docs/MESSAGES.md §1 and §4).

export interface ExpirySettings {
  days: number;
  min: number;
  max: number;
  scheduled: { id: number; days: number; from: string }[];
  history: {
    days: number;
    from: string;
    note: string | null;
    who: string;
    when: string | null;
    cancelled: boolean;
  }[];
}

/** One dated setting, worded by the database. */
export interface SettingCard {
  key: string;
  value: string;
  text: string;
  scheduled: { id: number; value: string; text: string; from: string }[];
  history: {
    value: string;
    text: string;
    from: string;
    note: string | null;
    who: string;
    when: string | null;
    cancelled: boolean;
  }[];
}

export interface RateRow {
  vehicle: 'savings' | 'gic';
  gic_term: number | null;
  what: string;
  rate: string;
  text: string;
  special_to: string | null;
  regular: string | null;
  scheduled: { id: number; text: string; special: boolean; from: string }[];
}

export interface SettingsData {
  today: string;
  today_text: string;
  expiry: ExpirySettings;
  rate_from: string;
  rate_to: string;
  /** The earliest day a cut can start (7 days' notice), e.g. "Oct 12". */
  cut_from_text: string;
  rates: RateRow[];
  rate_history: {
    what: string;
    text: string;
    special: boolean;
    note: string | null;
    who: string;
    when: string | null;
    cancelled: boolean;
  }[];
  cap: SettingCard;
  inflation: SettingCard;
  yields: { fund_id: string; name: string; card: SettingCard }[];
  features: { name: string; card: SettingCard }[];
  note_up: SettingCard;
  note_down: SettingCard;
  notes: { id: number; date: string; fund: string | null; body: string; for_kids: boolean }[];
  notes_total: number;
  glossary: { term: string; text: string }[];
  recent: { summary: string; who: string; when: string }[];
}

export interface PreviewNotice {
  title: string;
  body: string;
  kids: number;
  /** When she gets it: null = right away, otherwise the day ("Nov 1"). */
  on: string | null;
}
export interface ChangePreview {
  problem: string | null;
  summary: string | null;
  notices: PreviewNotice[];
  facts: Record<string, string | boolean | null> | null;
}

export type Parsed = { value: string } | { error: string };

/** Whole days typed by Dad, or a message. The database checks again. */
export function parseDays(text: string, min: number, max: number): number | string {
  const t = text.trim();
  if (t === '') return `Type a number of days from ${min} to ${max}.`;
  if (!/^\d{1,2}$/.test(t) || t.startsWith('0')) return `Use whole days, from ${min} to ${max}.`;
  const n = Number(t);
  if (n < min || n > max) return `Use whole days, from ${min} to ${max}.`;
  return n;
}

/**
 * A percent typed by Dad ("2.5", "2.5%", "0.75"), kept as text so it reaches the
 * database exactly (never a floating-point number). The database checks again.
 */
export function parsePercent(text: string): Parsed {
  const t = text.trim().replace(/\s*%$/, '');
  if (t === '') return { error: 'Type a percent, like 2.5.' };
  const m = t.match(/^(\d+)(?:\.(\d*))?$/) ?? t.match(/^()\.(\d+)$/);
  if (!m) return { error: 'Use numbers and a dot, like 2.5.' };
  const whole = (m[1] || '0').replace(/^0+(?=\d)/, '');
  const frac = (m[2] ?? '').replace(/0+$/, '');
  if (whole.length > 2) return { error: 'Use a percent below 100.' };
  if (frac.length > 3) return { error: 'Use at most 3 numbers after the dot, like 2.125.' };
  return { value: frac ? `${whole}.${frac}` : whole };
}

/** Wording typed by Dad: some words, at most `max` letters. */
export function parseWords(text: string, max: number): Parsed {
  const t = text.trim();
  if (t === '') return { error: 'Type some words.' };
  if (t.length > max) return { error: `Use at most ${max} letters (now ${t.length}).` };
  return { value: t };
}

export const FEATURES: Record<string, { name: string; about: string }> = {
  wishlist: { name: 'Wish List', about: 'Her Wish List tab and goals.' },
  personalisation: {
    name: 'Theme colours and avatars',
    about: 'She picks her colour and an animal avatar.',
  },
  badges: { name: 'Badges', about: 'Badges for good decisions, and the accessories they unlock.' },
};
export const SWITCH_CHOICES = [
  { value: 'off', label: 'Off' },
  { value: 'test', label: 'Test accounts only' },
  { value: 'everyone', label: 'Everyone' },
] as const;

/** "Savings" mid-sentence is "savings"; "1-year GIC" stays as it is. */
const inSentence = (what: string) => (what === 'Savings' ? 'savings' : what);

export const TEXT = {
  title: 'Settings',
  jump: 'Jump to',
  sections: {
    rates: 'Rates',
    limits: 'Cap and limits',
    money: 'Inflation and dividends',
    features: 'Feature switches',
    wording: 'Wording',
    logins: 'Logins',
    backup: 'Backup',
  },

  // Rates
  ratesExplain:
    'Tap Change, type the new rate and pick when it starts. New rates start in 7 days unless you pick another day, so the girls have time to react.',
  specialUntil: (to: string, regular: string | null) =>
    `Special until ${to}${regular ? `, then ${regular}` : ''}`,
  changeRate: (what: string) => `Change the ${inSentence(what)} rate`,
  rateHeading: (what: string) => `New ${inSentence(what)} rate`,
  rateLabel: 'New rate (% per year)',
  specialLabel: 'Limited-time special',
  specialHelp: 'A special goes back to the regular rate by itself after its last day.',
  rateStartsLabel: (special: boolean) => (special ? 'First day' : 'Starts on'),
  rateEndsLabel: 'Last day',
  rateNoteLabel: 'Note to the girls (optional), like “The Bank of Canada cut rates”',
  rateFacts: (f: Record<string, string | boolean | null>) =>
    f.special
      ? `${f.what} special: ${f.after} from ${f.from} to ${f.to}, then back to ${f.back_to}.`
      : `${f.what}: ${f.before ? `${f.before} → ` : ''}${f.after} from ${f.from}.`,
  lockedIn: 'GICs already bought keep their locked-in rate.',
  cutRule: (from: string) =>
    `A lower rate needs 7 days' notice so the girls can react: it can start on ${from} at the earliest. A higher rate can start today.`,
  yesRate: (f: Record<string, string | boolean | null> | null) =>
    f ? `Yes, save ${f.after}${f.special ? ' special' : ''} from ${f.from}` : 'Yes, save',
  rateHistory: 'History of rate changes',

  // Settings in general
  expiryTitle: 'Time to answer a request',
  expiryNow: (days: number) => `${days} days`,
  expiryExplain:
    "When she asks to put money in or take it out, you have this long to say yes or no. If you don't, the request is cancelled and any money on hold is freed. Each request keeps the time it had when she asked.",
  scheduled: (days: number, from: string) => `From ${from}: ${days} days`,
  scheduledText: (text: string, from: string) => `From ${from}: ${text}`,
  change: 'Change',
  changeHeading: 'Change how long you have to answer?',
  daysLabel: (min: number, max: number) => `Days to answer (${min} to ${max})`,
  startsLabel: 'Starts on',
  noteLabel: 'Note for your records (optional; the girls don’t see it)',
  capNoteLabel: 'Note to the girls (optional)',

  capTitle: 'Deposit cap',
  capExplain:
    'The most each girl can put in, minus what she takes out. Interest and gains don’t count. Lowering it never takes money away; it only stops new deposits until she’s under it again.',
  capRow: 'For each girl',
  perYear: 'Per year',
  capHeading: 'Change the deposit cap?',
  capRule: (from: string) =>
    `A lower cap needs 7 days' notice so the girls can react: it can start on ${from} at the earliest. A higher cap can start today.`,
  capLabel: 'New cap, in dollars (for both girls)',
  yesCap: (text: string) => `Yes, change to ${text}`,

  inflationTitle: 'Inflation rate',
  inflationExplain: 'Used by the inflation view. The Bank of Canada aims for 2.0%.',
  inflationHeading: 'Change the inflation rate?',
  percentLabel: 'New rate (% per year)',
  yieldsTitle: 'Dividend yields',
  yieldsExplain:
    'Each fund pays a quarter of its yearly yield into savings on the first market day of January, April, July and October.',
  yieldHeading: (fund: string) => `Change the ${fund} dividend yield?`,
  changeYield: (fund: string) => `Change the ${fund} yield`,
  yieldLabel: 'New yield (% per year)',
  yesPercent: (text: string) => `Yes, change to ${text}%`,
  yieldNoteLabel: 'Note to the girls (optional)',

  cancelChange: 'Cancel change',
  cancelLabel: (from: string) => `Cancel the change planned for ${from}`,
  cancelHeading: 'Cancel this planned change?',
  cancelExplain:
    "It won't happen. Nothing is deleted: the history keeps it, marked cancelled. A raise the girls were promised can only be cancelled 7 or more days before it starts.",
  cancelNoteLabel: 'Note to the girls (optional)',
  cancelQuiet: "The girls weren't told about this change, so they won't get a notice.",
  yesCancel: 'Yes, cancel this change',
  cancelledTag: ' (cancelled)',

  featuresTitle: 'Feature switches',
  featuresExplain:
    'Try a new feature on a test account first. “Everyone” turns it on for the girls too.',
  featureHeading: (name: string) => `Switch ${name}?`,
  changeFeature: (name: string) => `Change the ${name} switch`,
  switchLabel: 'Who has it',
  yesSwitch: (label: string) => `Yes, switch to ${label.toLowerCase()}`,

  notesTitle: 'Market-move notes',
  notesExplain:
    'When a fund moves more than 2% in a day, the girls see a note on its graph. The standard wording is used for new notes; notes already written keep theirs unless you edit them.',
  noteUp: 'Standard note for a big up day',
  noteDown: 'Standard note for a big down day',
  noteHeading: (up: boolean) => `Change the standard ${up ? 'up-day' : 'down-day'} note?`,
  changeNote: (up: boolean) => `Change the standard ${up ? 'up-day' : 'down-day'} note`,
  noteWordsLabel: 'New wording (at most 300 letters)',
  yesWords: 'Yes, save this wording',
  writtenTitle: (shown: number, total: number) =>
    shown < total ? `Notes already written (latest ${shown} of ${total})` : 'Notes already written',
  noNotes: 'No notes yet. One appears the first time a fund moves more than 2% in a day.',
  noteFor: (n: { date: string; fund: string | null }) => `${n.fund ?? 'All funds'}, ${n.date}`,
  editNote: (n: { date: string; fund: string | null }) =>
    `Edit the ${n.fund ?? ''} note for ${n.date}`.replace('  ', ' '),
  editHeading: 'Edit the wording',

  glossaryTitle: 'The ? explanations',
  glossaryExplain: 'What the girls read when they tap a ?. Keep it short and kid-friendly.',
  glossaryShow: (n: number) => `Show all ${n} explanations`,
  glossaryFilter: 'Find a word',
  glossaryNone: 'No word matches.',
  editTerm: (term: string) => `Edit the explanation of ${term}`,
  glossaryWordsLabel: 'New wording (at most 400 letters)',

  backupTitle: 'Backup',
  backupButton: 'Download backup',
  backupOff:
    'Arrives in stage 5, with the live setup. It will save every table as a zip of CSV and JSON files. Use it before big changes such as a rate change or a correction.',

  recentTitle: 'Recent changes',
  willRecord: 'This will be recorded:',
  theySee: (on: string | null, kids: number) =>
    on
      ? `On ${on}, ${kids === 1 ? 'she' : `every kid (${kids} accounts)`} will see:`
      : `${kids === 1 ? 'She' : `Every kid (${kids} accounts)`} will see this right away:`,
  noNotice: "The girls won't get a notice about this.",
  wordingQuiet: 'No notice: the girls simply see the new wording.',
  noNoticeSame: "The girls won't get a notice: the number isn't changing.",
  before: 'Now:',
  after: 'New:',
  fromTo: (f: Record<string, string | boolean | null>) =>
    `${f.before ?? 'Not set'} → ${f.after}, from ${f.from}.`,
  checking: 'Checking…',
  yes: (days: number) => `Yes, change to ${days} days`,
  back: 'Back',
  saving: 'Saving…',
  done: (summary: string, who: string, when: string) =>
    `Done. ${summary} Recorded: ${who}, ${when}.`,
  history: 'History',
  historyLine: (h: { days: number; from: string; cancelled?: boolean }) =>
    `${h.days} days from ${h.from}${h.cancelled ? ' (cancelled)' : ''}`,
  historyText: (h: { text: string; from: string; cancelled?: boolean }) =>
    `${h.text} from ${h.from}${h.cancelled ? ' (cancelled)' : ''}`,
  historyWho: (h: { who: string; when: string | null }) => (h.when ? `${h.who}, ${h.when}` : h.who),
  loadError: (e: string) => `Couldn't load Settings: ${e}`,
  retry: 'Try again',
};

/** Settings → Logins (PIN reset, Dad's decision 2026-10-08). */
export interface KidLogin {
  account_id: string;
  name: string;
  is_test: boolean;
  username: string;
  reset_pending: boolean;
  reset_expires: string | null;
  /** Her code ran out before she used it: her old PIN no longer works either. */
  reset_expired: boolean;
}

export const LOGINS = {
  title: 'Logins',
  intro:
    'If a girl forgets her PIN (or someone else may know it), reset it here. She gets a one-time code from you, then chooses a new PIN at her next sign-in.',
  test: '(test account)',
  reset: (name: string) => `Reset ${name}'s PIN`,
  confirm: (name: string) =>
    `${name}'s PIN stops working now, and she's signed out on every device. You'll get a one-time code to give her: at her next sign-in she types it, then chooses a new PIN. She gets a notice.`,
  yes: (name: string) => `Reset ${name}'s PIN`,
  cancel: 'Cancel',
  giveCode: (name: string) => `Give ${name} this code:`,
  codeOnce:
    "It works for 7 days, and it's shown only this once. If it's lost, reset her PIN again.",
  pending: (until: string | null) =>
    `Waiting for her to choose a new PIN${until ? ` (her code works until ${until})` : ''}.`,
  expired: "Her code ran out before she used it, so she can't sign in. Reset her PIN again.",
  done: 'Done',
};

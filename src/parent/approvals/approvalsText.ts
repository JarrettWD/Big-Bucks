// The Approvals screen's words, for Dad (plainer than the kid side). Nothing here
// is shown to the girls: what they see comes from the database's notices, which
// the screen previews word for word (docs/MESSAGES.md §1).
//
// No money arithmetic here: every amount, including "savings after", comes from
// parent_inbox(). The only sum is the countdown's seconds.

import { formatCents } from '../../lib/money';
import type { WaitingRequest } from '../useInbox';

/** Seconds left on a countdown the database started, after `elapsedMs` on this screen. */
export function secondsLeft(serverSeconds: number, elapsedMs: number): number {
  return Math.max(0, serverSeconds - Math.floor(Math.max(0, elapsedMs) / 1000));
}

/** "18 h 30 min", "1 h", "12 min", "under a minute". Minutes round up, so it never
 *  says a wait is over before it is. */
export function formatWait(seconds: number): string {
  if (seconds <= 0) return 'now';
  if (seconds < 60) return 'under a minute';
  const minutes = Math.ceil(seconds / 60);
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return `${m} min`;
  return m === 0 ? `${h} h` : `${h} h ${m} min`;
}

const kind = (r: WaitingRequest) => (r.type === 'deposit' ? 'deposit' : 'withdrawal');

export const requestTitle = (r: WaitingRequest) =>
  `${r.type === 'deposit' ? 'Deposit' : 'Withdrawal'} ${formatCents(r.amount_cents)}`;

export const requestIcon = (r: WaitingRequest) => (r.type === 'deposit' ? '💵' : '👛');

/** The money behind the request, as label/value pairs. */
export function requestFacts(r: WaitingRequest): [string, string][] {
  if (r.type === 'deposit')
    return [
      ['Deposit cap', formatCents(r.cap_cents)],
      ['Put in so far', formatCents(r.net_deposits_cents)],
      ['Waiting (this included)', formatCents(r.pending_deposits_cents)],
      ['Room left after all waiting', formatCents(r.cap_room_cents)],
    ];
  return [
    ['Savings', formatCents(r.savings_cents)],
    ['On hold (this included)', formatCents(r.held_cents)],
    ['Free to use', formatCents(r.available_cents)],
  ];
}

export const waitLine = (r: WaitingRequest, left: number) =>
  `24-hour wait: you can approve from ${r.approve_from} (in ${formatWait(left)}).`;

export function expiryLine(r: WaitingRequest, left: number): string {
  if (left <= 0) return "This has expired. Tonight's run releases it, and she's told why.";
  if (left < 24 * 3600) return `Expires in ${formatWait(left)} (${r.expires}) if you don't answer.`;
  return `Expires ${r.expires} if you don't answer.`;
}

export const approveHeading = (r: WaitingRequest) =>
  `Approve ${r.kid}'s ${formatCents(r.amount_cents)} ${kind(r)}?`;

export function approveCashLine(r: WaitingRequest): string {
  const amount = formatCents(r.amount_cents);
  const change = `${formatCents(r.savings_cents)} → ${formatCents(r.savings_after_cents)}`;
  return r.type === 'deposit'
    ? `Only approve once you have ${r.kid}'s ${amount} in cash. It goes into her savings right away: ${change}.`
    : `Only approve when you hand ${r.kid} ${amount} in cash. It comes out of her savings right away: ${change}.`;
}

export const declineHeading = (r: WaitingRequest) =>
  `Decline ${r.kid}'s ${formatCents(r.amount_cents)} ${kind(r)}?`;

export const declineLine = (r: WaitingRequest) =>
  r.type === 'deposit'
    ? 'Nothing changes in her account. She sees your reason.'
    : 'The money on hold is released back to her. She sees your reason.';

export const TEXT = {
  title: 'Approvals',
  money: 'Deposits and withdrawals',
  moneyEmpty: 'Nothing waiting. 🎉',
  questions: 'Questions',
  questionsEmpty: 'No open questions.',
  recent: 'Recent decisions',
  recentEmpty: 'Nothing yet.',
  test: 'Test',
  asked: (when: string) => `Asked ${when}`,
  approve: 'Approve',
  decline: 'Decline',
  answer: 'Answer',
  fix: 'Fix a mistake',
  back: 'Back',
  yesApprove: (r: WaitingRequest) => `Yes, approve ${formatCents(r.amount_cents)}`,
  yesDecline: 'Yes, decline',
  sendAnswer: 'Send answer',
  noteLabel: (kid: string) => `Note to ${kid} (optional)`,
  reasonLabel: (kid: string) => `Reason (${kid} sees this)`,
  answerLabel: (kid: string) => `Your answer (${kid} sees this)`,
  answerHeading: (kid: string) => `Answer ${kid}'s question`,
  sheSees: (kid: string) => `${kid} will see:`,
  previewWaiting: 'Type your words to see what she gets.',
  checking: 'Checking…',
  saving: 'Saving…',
  aboutLine: 'About this line in her history:',
  noLine: 'Not about a particular line.',
  calc: 'How it was calculated:',
  done: (summary: string, who: string, when: string) =>
    `Done. ${summary} Recorded: ${who}, ${when}.`,
  loadError: (e: string) => `Couldn't load the approvals: ${e}`,
  retry: 'Try again',
  updated: (now: string) => `Up to date as of ${now}.`,
};

/** Countersigning the girls' agreements (stage 8 B4). Dad's wording. */
export const AGREE = {
  title: 'Agreements to sign',
  empty: 'Nothing to sign.',
  signedBy: (k: { kid: string; signed_version: number | null }) =>
    `${k.kid} signed her Big Bucks agreement${k.signed_version && k.signed_version > 1 ? ` (version ${k.signed_version})` : ''}`,
  read: 'Read and sign',
  heading: (kid: string) => `Sign ${kid}'s agreement?`,
  explain: (kid: string) =>
    `This is exactly what ${kid} signed, with the numbers of that day. Read it through, then sign it too.`,
  checking: 'Checking…',
  willRecord: 'This will be recorded:',
  sheSees: (kid: string) => `${kid} will see:`,
  yes: (kid: string) => `Yes, sign ${kid}'s agreement`,
  back: 'Back',
  saving: 'Saving…',
  done: (summary: string, who: string, when: string) =>
    `Done. ${summary} Recorded: ${who}, ${when}.`,
  toSign: (kids: string[]) =>
    `${kids.join(' and ')} signed ${kids.length === 1 ? 'her' : 'their'} agreement and ${kids.length === 1 ? 'is' : 'are'} waiting for you.`,
  signNow: 'Sign it',
  notStarted: (kid: string) => `${kid} hasn't started setting up Big Bucks yet.`,
};

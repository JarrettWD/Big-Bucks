// The words on the Wish List and the goal card. The database sends the facts (her
// total worth, each wish's percent, the projected month, whether her funds went down
// this week); this only chooses the words. Every message here is in docs/MESSAGES.md §12.

import { toCents, type Cents } from '../../lib/money';

// What the database sends ---------------------------------------------------------------------

export interface Wish {
  id: string;
  name: string;
  price_cents: Cents | null;
  link: string | null;
  stars: number;
  status: 'wanted' | 'goal';
  has_photo: boolean;
  photo_at: string | null;
  added_on: string;
  /** "Fri Oct 23": the first day it can become a goal. */
  goal_from: string;
  can_goal: boolean;
  percent: number | null;
  enough: boolean;
  months: number | null;
  /** "January 2028", or null past 5 years. */
  around: string | null;
  /** Parent view only. */
  marked?: boolean;
  mark_note?: string | null;
  marked_on?: string | null;
}

export interface DoneWish {
  id: string;
  name: string;
  price_cents: Cents | null;
  link: string | null;
  stars: number;
  status: 'got_it' | 'removed';
  has_photo: boolean;
  photo_at: string | null;
  done_on: string | null;
  marked?: boolean;
  mark_note?: string | null;
  marked_on?: string | null;
}

export interface WishList {
  today: string;
  worth_cents: Cents;
  rate: string | number | null;
  funds_dipped: boolean;
  photos_used: number;
  photos_max: number;
  items: Wish[];
  done: DoneWish[];
}

export interface Goal {
  id: string;
  name: string;
  price_cents: Cents;
  worth_cents: Cents;
  has_photo: boolean;
  photo_at: string | null;
  percent: number;
  enough: boolean;
  months: number | null;
  around: string | null;
  funds_dipped: boolean;
}

// Words ----------------------------------------------------------------------------------------

export const TEXT = {
  title: 'Wish List',
  seeLine: 'Mom and Dad can see your wish list.',
  intro: "Things you'd love to have. Put the one you want most at the top.",
  empty: 'Your wish list is empty. What would you love to save up for?',
  add: 'Add a wish',
  addTitle: 'What would you love to save up for?',
  editTitle: 'Change this wish',
  name: 'What is it?',
  price: 'About how much? (you can skip this)',
  stars: 'How much do you want it? (1 to 5 stars)',
  link: 'A link to it (you can skip this)',
  linkHelp: 'Copy the address from the shop’s page and paste it here.',
  photo: 'A photo (you can skip this)',
  addPhoto: 'Add a photo',
  changePhoto: 'Change the photo',
  removePhoto: 'Remove the photo',
  photoBusy: 'Getting your photo ready…',
  photosFull: (max: number) => `You've used all ${max} photo spots. Remove a photo first.`,
  save: 'Save',
  addIt: 'Add it',
  skip: 'Skip for now',
  cancel: 'Cancel',
  edit: 'Change',
  moveUp: (name: string) => `Move ${name} up`,
  moveDown: (name: string) => `Move ${name} down`,
  added: (days: string) =>
    `Added to your Wish List! If you still want it in ${days} days, you can make it a savings goal.`,
  goalTag: 'Your goal',
  waitLine: (day: string) => `Still want this on ${day}? Then you can make it a savings goal.`,
  makeGoal: 'Make it my goal',
  stillWant: 'Still want this?',
  stillWantWhy:
    'A goal is something you really want, not just something you saw today. Is this still it?',
  yesGoal: 'Yes, make it my goal',
  notNow: 'Not now',
  needPrice: 'Add a rough price first, so you can see how close you are.',
  switchTitle: (current: string, next: string) =>
    `You're saving for ${current}. Switch your goal to ${next}?`,
  switchWhy: (current: string) => `${current} stays on your wish list.`,
  yesSwitch: 'Yes, switch',
  keepGoal: 'Keep my goal',
  stopGoal: 'Stop saving for this',
  gotIt: 'I got this',
  remove: 'Remove',
  removeTitle: (name: string) => `Remove ${name} from your list?`,
  removeWhy: 'It moves to your Done list, so you can still see it.',
  gotItTitle: (name: string) => `You got ${name}? Hooray!`,
  gotItWhy: 'It moves to your Done list.',
  yesRemove: 'Yes, remove it',
  yesGotIt: 'Yes, I got it',
  doneTitle: 'Done',
  doneIntro: 'Things you got, or took off your list.',
  doneGot: 'You got it!',
  doneRemoved: 'Removed',
  openLink: 'Open link',
  linkOutside: 'This opens outside Big Bucks.',
  nameLocked: 'Stop saving for this goal first if you want to change its name.',
  loadError: "Big Bucks couldn't load your wish list just now. Please try again in a minute.",
  retry: 'Try again',
  photoAlt: (name: string) => `Photo of ${name}`,
  closePhoto: 'Close',
  goalCardTitle: 'Your goal',
  seeWishList: 'See your Wish List',
  starsLabel: (n: number) => (n === 1 ? '1 star' : `${n} stars`),
};

/** "You're 40% of the way there." (or why there's no percent). */
export function progressLine(w: Pick<Wish, 'percent' | 'enough' | 'price_cents'>): string {
  if (w.price_cents === null || w.percent === null)
    return 'Add a rough price to see how close you are.';
  if (w.enough) return 'You have enough for this! Talk to Mom and Dad about it.';
  return `You're ${w.percent}% of the way there.`;
}

/** Roughly when, worded so it never sounds like a promise. Null when there's nothing to say. */
export function projectionLine(
  w: Pick<Wish, 'percent' | 'enough' | 'price_cents' | 'months' | 'around'>,
  worthCents: Cents,
): string | null {
  if (w.price_cents === null || w.percent === null || w.enough) return null;
  if (toCents(worthCents) <= 0n)
    return "Once you have some money saved, you'll see roughly when you could have enough.";
  if (w.around === null)
    return 'Interest alone would take more than 5 years. Adding money, like birthday or allowance money, is the fastest way there.';
  return `If your money keeps growing like your savings does now, and you add nothing, you could have enough around ${w.around}. That's a guess, not a promise. Adding money gets you there sooner.`;
}

/** Her progress went down because her funds did (MESSAGES §12, Dad 2026-10-16). */
export const DIP_LINE =
  "Your funds went down this week, so you're a bit further away. That's normal: funds go up and down.";

/** Show the "went down" line on a wish that isn't reached yet. */
export const showDip = (dipped: boolean, w: Pick<Wish, 'enough' | 'percent'>) =>
  dipped && !w.enough && w.percent !== null;

/**
 * The site's name for a link she pasted, never the link itself: "shop.example.com"
 * (without "www."). Look-alike letters show in their xn-- form, the way the browser's
 * own URL parser writes the site, so a fake shop can't pass for a real one. Null when
 * it isn't a web link.
 */
export function siteName(link: string | null): string | null {
  if (!link) return null;
  try {
    const u = new URL(link);
    if (u.protocol !== 'https:' && u.protocol !== 'http:') return null;
    return u.hostname.replace(/^www\./, '') || null;
  } catch {
    return null;
  }
}

/** Safe to put in an <a href>: only http(s), exactly as the database stored it. */
export function safeHref(link: string | null): string | null {
  return siteName(link) === null ? null : link;
}

// Onboarding, the account agreement and What's new: her words, from
// docs/MESSAGES.md §11 (reviewed by Dad 2026-10-05). Every number is a
// {placeholder} filled from house_rules(), which the database reads from the
// settings in force and the engine's own rules. Nothing here is typed in.

import { formatCents } from '../../lib/money';

/** house_rules(): the placeholder values, already in words ("$1,000.00", "7"). */
export type HouseRules = Record<string, string>;

export interface AgreementRule {
  icon: string;
  title: string;
  text: string;
  glossary?: string;
  mark?: 'new' | 'changed';
}

export interface AgreementDoc {
  version: number;
  title: string;
  intro: string;
  rules: AgreementRule[];
  promises: string;
  sign_line: string;
  name: string;
}

export interface OnboardingState {
  name: string;
  done: boolean;
  current_version: number;
  signed_version: number | null;
  countersigned: boolean;
  needs_signature: boolean;
  steps: Step[];
  agreement: AgreementDoc;
  first_deposit_cents: number | null;
  free_cents: number;
  min_invest_cents: number;
  rules: HouseRules;
  /** Where she left off (null once onboarding is done), and which tour card. */
  resume_step: Step | null;
  resume_card: number;
  /** A deposit she has asked for that Dad hasn't answered yet. */
  pending_deposit_cents: number | null;
  /** Both signed and her first deposit in (or onboarding done): the app is hers. */
  unlocked: boolean;
  /** Her first deposit request, if Dad said no or it ran out of time. */
  last_answer: {
    status: 'declined' | 'expired';
    amount_cents: number;
    reason: string | null;
  } | null;
}

export interface SignedAgreement {
  version: number;
  copy: AgreementDoc;
  signed_on: string;
  dad_signed_on: string | null;
}

export type Step = 'welcome' | 'tour' | 'personalise' | 'wish' | 'agreement' | 'decision';

/**
 * Steps with screens in this app. "Make it yours" and "your first wish" arrive
 * with their features (stages 10 and 9); until then they're skipped.
 */
export const BUILT_STEPS: Step[] = ['welcome', 'tour', 'agreement', 'decision'];

export function shownSteps(state: Pick<OnboardingState, 'steps'>): Step[] {
  return state.steps.filter((s) => BUILT_STEPS.includes(s));
}

/** "{cap}" → "$1,000.00", from house_rules(). An unknown placeholder is left alone. */
export function fill(text: string, rules: HouseRules): string {
  return text.replace(/\{([a-z_]+)\}/g, (m, k: string) => rules[k] ?? m);
}

/** A rule's bold title and its text, joined the way MESSAGES §11 reads. */
export function ruleSentence(r: AgreementRule): { title: string; rest: string } {
  return { title: r.title, rest: r.text.startsWith(',') ? r.text : ` ${r.text}` };
}

/**
 * Where she starts: where she left off (saved by the database), her first decision
 * once she has signed, or the new version of the agreement after onboarding.
 */
export function firstStep(state: OnboardingState): Step {
  if (state.done) return state.needs_signature ? 'agreement' : 'welcome';
  const step = state.resume_step ?? 'welcome';
  return shownSteps(state).includes(step) ? step : 'welcome';
}

const STEP_NAMES: Record<Step, string> = {
  welcome: 'Welcome',
  tour: 'A quick look around',
  personalise: 'Make it yours',
  wish: 'Your first wish',
  agreement: 'Your Big Bucks agreement',
  decision: 'Your first decision',
};

export const stepList = (steps: Step[]) =>
  steps.filter((s) => s !== 'welcome').map((s) => STEP_NAMES[s]);

export interface TourCard {
  title: string;
  lines: { text: string; term?: string; strong?: string }[];
}

/** The tour (MESSAGES §11, step 1). The Wish List card only if it's on for her. */
export function tourCards(rules: HouseRules, wishList: boolean): TourCard[] {
  const cards: TourCard[] = [
    {
      title: 'Home 🏠',
      lines: [
        {
          text: 'Home shows everything you have. Your total worth is at the top.',
          term: 'Total worth',
        },
        { text: 'Under it are your three ways to grow money: savings, GICs and stock funds.' },
        { text: "When something needs you, like a GIC that's finished, a banner tells you." },
      ],
    },
    {
      title: 'Three ways to grow your money',
      lines: [
        {
          text: 'Each one has a good side and a catch: getting your money back quickly, or giving it time to grow more.',
        },
        {
          strong: '🐷 Savings',
          term: 'Savings account',
          text: fill(
            ': safe, and ready whenever you need it. It earns {savings_rate} a year in interest, paid on the 1st of every month. New money always lands here first.',
            rules,
          ),
        },
        {
          strong: '🔒 GICs',
          term: 'GIC',
          text: fill(
            ': you promise to leave your money alone for a while, from 1 month to 2 years (the term). In return you earn more: right now from {gic_lowest} to {gic_highest} a year. Your rate is locked in the day you buy.',
            rules,
          ),
        },
        {
          strong: '📈 Stock funds',
          term: 'Stock fund',
          text: ': a tiny piece of lots of companies, in three funds: Dow Jones, Nasdaq-100 and TSX. Over many years they have usually grown the most, but they go up and down, and they can be worth less than you put in.',
        },
      ],
    },
    {
      title: 'Graphs 📊',
      lines: [
        { text: 'Graphs show how your money has grown, and how each option did.' },
        { text: 'Tap any ? to learn what a word means.' },
      ],
    },
    {
      title: 'Buy / Sell 🔁',
      lines: [
        { text: 'This is where you move your money.' },
        {
          text: 'Putting money in or taking it out waits for Dad, because real cash changes hands.',
        },
        {
          text: 'Moving money between your options happens by itself. Stock funds buy and sell at the next market close.',
          term: 'Market close',
        },
      ],
    },
  ];
  if (wishList)
    cards.push({
      title: 'Wish List ⭐',
      lines: [
        { text: "Add things you'd love to have, and see how close you are." },
        { text: 'Mom and Dad can see your wish list.' },
      ],
    });
  cards.push({
    title: 'The bell 🔔',
    lines: [
      {
        text: "Notices from Dad and from Big Bucks land here, like a new rate or a request that's done.",
      },
      { text: 'A number on the bell means something new to read.' },
    ],
  });
  return cards;
}

export interface Choice {
  key: 'savings' | 'gic' | 'fund';
  title: string;
  text: string;
}

/** The first decision: only the choices her free savings can cover. */
export function decisionChoices(state: OnboardingState): { choices: Choice[]; note: string } {
  const r = state.rules;
  const savings: Choice = {
    key: 'savings',
    title: '🐷 Keep it in savings.',
    text: fill(
      'Safe and ready any time, earning {savings_rate} a year. Waiting is a real choice too.',
      r,
    ),
  };
  if (state.free_cents < state.min_invest_cents)
    return {
      choices: [savings],
      note: fill('Once you have {min_invest}, you can try a GIC or a fund.', r),
    };
  return {
    choices: [
      savings,
      {
        key: 'gic',
        title: '🔒 Put some in a GIC.',
        text: fill(
          'Earn more ({gic_lowest} to {gic_highest} a year right now) by promising to leave it alone.',
          r,
        ),
      },
      {
        key: 'fund',
        title: '📈 Try a stock fund.',
        text: 'It could grow the most over time, but it can also go down.',
      },
    ],
    note: 'Lots of people split their money between options. You can change your mind later (except that a GIC is a promise).',
  };
}

/** Her history's line for a signed agreement (MESSAGES §11). */
export function agreementLine(a: SignedAgreement): string {
  const name =
    a.version === 1
      ? 'Your Big Bucks agreement'
      : `Your Big Bucks agreement (version ${a.version})`;
  return a.dad_signed_on
    ? `${name} · signed ${a.signed_on}, Dad signed ${a.dad_signed_on}`
    : `${name} · signed ${a.signed_on}, waiting for Dad to sign`;
}

export const TEXT = {
  welcomeTitle: (name: string) => `Welcome to Big Bucks, ${name}!`,
  tagline: 'Watch your bucks grow.',
  welcomeBody:
    'This is your very own bank and investing account. The money is real: Dad keeps the cash, and Big Bucks keeps track of every cent.',
  together: "What we'll do together",
  getStarted: "Let's get started",
  next: 'Next',
  back: 'Back',
  done: 'Done',
  signButton: 'Sign my agreement',
  signing: 'Signing…',
  signedTitle: "You signed it! Now it's Dad's turn.",
  signedBody: "Dad signs on his own phone. You'll get a notice when he does.",
  dadSigned: 'Dad has signed it too.',
  promises: "Dad's promises",
  newMark: 'New',
  changedMark: 'Changed',
  beforeDepositTitle: 'Your first decision starts with your first deposit.',
  beforeDeposit: 'Ask Dad to put some money in. It goes into your savings once he says yes.',
  depositLabel: 'How much would you like to put in?',
  depositEmpty: 'Type how much first.',
  depositConfirm: (cents: number) => `You're asking Dad to put in ${formatCents(cents)}.`,
  askDad: 'Ask Dad',
  asking: 'Asking…',
  waitingForDad: (cents: number) => `You asked to put in ${formatCents(cents)}. Waiting for Dad.`,
  askedBody: 'When he says yes, your first decision is next.',
  checkAgain: 'Check again',
  declinedTitle: 'Dad said not this time.',
  declinedReason: (reason: string) => `Dad says: “${reason}”`,
  expiredTitle: 'Your request ran out of time.',
  askAgain: 'You can ask again.',
  waitingForDadSign:
    "Dad hasn't signed your agreement yet. Once he does, your first decision is next.",
  keepGoing: 'Keep going',
  locked: 'Finish setting up first, then all of Big Bucks is yours!',
  goToTrade: 'Go to Buy / Sell',
  backHome: 'Back to Home',
  firstIn: (amount: number) => `🎉 Your first ${formatCents(amount)} is in your savings!`,
  decisionBody:
    "Now for your first big decision: what should your money do? There's no wrong answer.",
  allSet: 'You made your first money decision. Nice thinking!',
  welcomeAboard: "You're all set. Welcome to Big Bucks!",
  goHome: 'Go to Home',
  setupBanner: "👋 Let's set up your Big Bucks with Dad.",
  setupContinue: "👋 Let's finish setting up your Big Bucks.",
  changedBanner: 'Your Big Bucks agreement has changed.',
  readIt: 'Read it',
  historyTitle: 'Your Big Bucks agreement',
  historyNone: "You haven't signed your Big Bucks agreement yet.",
  afterSigning:
    'Numbers like your deposit cap can change after you sign. When one does, you get a notice in the bell.',
  showMe: 'Show me',
  gotIt: 'Got it',
  loadError: "Big Bucks couldn't load this just now. Please try again in a minute.",
  retry: 'Try again',
};

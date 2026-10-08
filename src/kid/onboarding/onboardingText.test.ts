import { describe, expect, it } from 'vitest';
import {
  agreementLine,
  decisionChoices,
  fill,
  firstStep,
  ruleSentence,
  shownSteps,
  stepList,
  tourCards,
  type OnboardingState,
} from './onboardingText';

const rules = {
  cap: '$1,000.00',
  expiry_days: '7',
  savings_rate: '2.0%',
  gic_lowest: '2.5%',
  gic_highest: '6.0%',
  cut_notice_days: '7',
  withdraw_wait_hours: '24',
  min_savings: '$5.00',
  min_invest: '$10.00',
  gic_choice_days: '7',
  goal_wait_days: '7',
};

const state = (s: Partial<OnboardingState>): OnboardingState => ({
  name: 'Robin',
  done: false,
  current_version: 1,
  signed_version: null,
  countersigned: false,
  needs_signature: true,
  steps: ['welcome', 'tour', 'agreement', 'decision'],
  agreement: {
    version: 1,
    title: '',
    intro: '',
    rules: [],
    promises: '',
    sign_line: '',
    name: 'Robin',
  },
  first_deposit_cents: null,
  free_cents: 0,
  min_invest_cents: 1000,
  rules,
  resume_step: 'welcome',
  resume_card: 0,
  pending_deposit_cents: null,
  unlocked: false,
  last_answer: null,
  ...s,
});

describe('onboarding wording (stage 8 B4)', () => {
  it('fills numbers from the house rules, never typed in', () => {
    expect(fill('up to {cap}, {expiry_days} days, {nope}', rules)).toBe(
      'up to $1,000.00, 7 days, {nope}',
    );
    expect(fill('{savings_rate}', { ...rules, savings_rate: '1.5%' })).toBe('1.5%');
  });
  it('skips the steps whose features are not built yet, and lists the rest', () => {
    const s = state({ steps: ['welcome', 'tour', 'personalise', 'wish', 'agreement', 'decision'] });
    expect(shownSteps(s)).toEqual(['welcome', 'tour', 'agreement', 'decision']);
    expect(stepList(shownSteps(s))).toEqual([
      'A quick look around',
      'Your Big Bucks agreement',
      'Your first decision',
    ]);
  });
  it('resumes where she left off, or at the agreement to sign again', () => {
    expect(firstStep(state({}))).toBe('welcome');
    expect(firstStep(state({ resume_step: 'tour', resume_card: 3 }))).toBe('tour');
    expect(firstStep(state({ resume_step: 'agreement' }))).toBe('agreement');
    expect(firstStep(state({ resume_step: 'wish' }))).toBe('welcome'); // not built yet
    expect(
      firstStep(state({ signed_version: 1, needs_signature: false, resume_step: 'decision' })),
    ).toBe('decision');
    expect(firstStep(state({ signed_version: 1, needs_signature: true, done: true }))).toBe(
      'agreement',
    );
    expect(firstStep(state({ signed_version: 1, needs_signature: false, done: true }))).toBe(
      'welcome',
    );
  });
  it('joins a rule the way the agreement reads', () => {
    expect(
      ruleSentence({ icon: '📣', title: 'Rates can change', text: ', like at a real bank.' }).rest,
    ).toBe(', like at a real bank.');
    expect(
      ruleSentence({ icon: '🔑', title: 'Your PIN is yours.', text: "Don't share it." }).rest,
    ).toBe(" Don't share it.");
  });
  it('tours with the rates of the day, and the Wish List only when it is on', () => {
    const cards = tourCards(rules, false);
    expect(cards.map((c) => c.title)).toEqual([
      'Home 🏠',
      'Three ways to grow your money',
      'Graphs 📊',
      'Buy / Sell 🔁',
      'The bell 🔔',
    ]);
    expect(cards[1].lines[2].text).toContain('right now from 2.5% to 6.0% a year');
    expect(tourCards(rules, true).map((c) => c.title)).toContain('Wish List ⭐');
  });
  it('offers only the choices she can afford', () => {
    const small = decisionChoices(state({ free_cents: 999 }));
    expect(small.choices.map((c) => c.key)).toEqual(['savings']);
    expect(small.note).toBe('Once you have $10.00, you can try a GIC or a fund.');
    const enough = decisionChoices(state({ free_cents: 1000 }));
    expect(enough.choices.map((c) => c.key)).toEqual(['savings', 'gic', 'fund']);
    expect(enough.choices[1].text).toBe(
      'Earn more (2.5% to 6.0% a year right now) by promising to leave it alone.',
    );
  });
  it('names a signed agreement in her history', () => {
    expect(
      agreementLine({
        version: 1,
        copy: state({}).agreement,
        signed_on: 'Oct 5',
        dad_signed_on: 'Oct 5',
      }),
    ).toBe('Your Big Bucks agreement · signed Oct 5, Dad signed Oct 5');
    expect(
      agreementLine({
        version: 2,
        copy: state({}).agreement,
        signed_on: 'Nov 2',
        dad_signed_on: null,
      }),
    ).toBe('Your Big Bucks agreement (version 2) · signed Nov 2, waiting for Dad to sign');
  });
});

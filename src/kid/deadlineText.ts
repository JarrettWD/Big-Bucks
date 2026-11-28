// A passed deadline, shown straight away (block 1, item 4; Dad 2026-11-24, wording 2026-11-27).
// The database says when a deadline has passed (gic_positions.choice_over, a waiting request's
// expired) and whether tonight's run is still to come (cancels_tonight); these only put words
// around it. Time comes from the database, never the phone's clock.

import { formatCents, type Cents } from '../lib/money';

/** The evening a request is cancelled: tonight, unless tonight's run is already done. */
const when = (tonight: boolean) => (tonight ? 'tonight' : 'tomorrow evening');

export const GIC_TIME_UP = "Time's up for this GIC.";

/** "Your $30.07 goes into your savings tonight." (the run moves it the evening of choice_ends) */
export const gicGoesToSavings = (balance: Cents) =>
  `Your ${formatCents(balance)} goes into your savings tonight.`;

/** Her waiting list: a deposit or withdrawal past its days, worded for its kind. */
export function requestRanOut(type: 'deposit' | 'withdraw', tonight: boolean): string {
  return type === 'withdraw'
    ? `This request ran out of time. It will be cancelled ${when(tonight)}, and its money is no longer on hold after that.`
    : `This request ran out of time. It will be cancelled ${when(tonight)}.`;
}

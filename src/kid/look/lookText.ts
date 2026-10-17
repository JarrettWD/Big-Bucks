// The wording for "Make it yours" and her badges (stage 10, MESSAGES §13).

import { formatDate } from '../../lib/format';

export const TEXT = {
  lookTitle: 'Make it yours',
  pickColour: 'Pick your colour',
  pickAnimal: 'Pick your animal',
  pickWear: 'Something to wear',
  none: 'None',
  anyTime: 'You can change these any time.',
  save: 'Looks great!',
  saved: 'Saved!',
  viewing: '"View as" can\'t change anything.',
  openLook: 'Change your colour and animal',
  badgesLink: '🏅 Your badges',
  badgesTitle: 'Your badges',
  badgesIntro:
    'Badges are for smart money choices. Each one unlocks something fun for your animal to wear.',
  earnedHead: 'Your badges',
  todoHead: 'Still to discover',
  noneYet: 'No badges yet. They come from smart money choices, like the ones below.',
  wear: 'Wear it',
  wearing: 'Wearing it ✓',
  pickAnimalFirst: 'Pick an animal first, then it can wear this.',
} as const;

export const earnedOn = (day: string, thisYear: number) => `Earned ${formatDate(day, thisYear)}`;

export interface BadgeKind {
  key: string;
  name: string;
  emoji: string;
  accessory: string;
  accessory_name: string;
  earned_line: string;
  todo_line: string;
}
export interface EarnedBadge {
  badge: string;
  earned_on: string;
  awarded_at: string;
  accessory: string;
  related_fund: string | null;
}
export interface Badges {
  on: boolean;
  earned: EarnedBadge[];
  kinds: BadgeKind[];
}

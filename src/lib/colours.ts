// The colours every screen uses, in one place, so the contrast test can check
// them all. CSS reads the same values from theme.css; colours.test.ts keeps the
// two in step.
//
// Rules (WCAG 2.2 AA):
//   * text: at least 4.5 : 1 against its background (3 : 1 for large text);
//   * shapes that carry meaning (bars, dots, sparklines): at least 3 : 1 against
//     what's next to them. Fills too light for that (savings gold, the fund
//     orange) always get the OUTLINE around them, and every coloured shape also
//     has a text label, so colour is never the only clue.
//   * The savings gold is for fills only, never text.

export const BRAND = {
  purple: '#5B3FD1',
  gold: '#FFD166',
  pink: '#FF4F87',
  white: '#FFFFFF',
} as const;

export const INK = {
  ink: '#1F1640', // main text
  inkSoft: '#5A5277', // secondary text
  page: '#F7F5FF', // kid page background
  purpleTint: '#EFEBFF', // soft panels
  purpleDeep: '#4A2FB5', // the dark end of the total-worth panel
  outline: '#5A5277', // the outline around coloured shapes
} as const;

/** Up and down days: calm, and equally clear. Neither is red. */
export const MOVE = {
  up: '#15693D',
  down: '#6A4C9C',
  flat: '#5A5277',
} as const;

/** The option colours, the same everywhere. The funds' come from the database (funds.colour). */
export const OPTION = {
  savings: '#E0A400',
  gic: '#A82250',
  dow: '#146DE4',
  nasdaq100: '#F06008',
  tsx: '#074945',
} as const;

/** When an option's name or status is written in its own colour, this shade is used. */
export const OPTION_TEXT = {
  gic: '#A82250',
} as const;

// ---- contrast maths (WCAG relative luminance) ----

function channel(c: number): number {
  const s = c / 255;
  return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
}

export function luminance(hex: string): number {
  const m = hex.match(/^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i);
  if (!m) throw new Error(`Not a colour: ${hex}`);
  const [r, g, b] = m.slice(1).map((h) => channel(parseInt(h, 16)));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

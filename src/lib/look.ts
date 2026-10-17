// "Make it yours" (stage 10): her theme colours, the animals and the accessories.
// The database keeps the same keys (look_themes(), look_animals(), badge_kinds) and
// refuses anything else; look.test.ts keeps the two lists in step and checks every
// colour's contrast. The pictures are app files in public/avatars (Fluent Emoji by
// Microsoft, MIT; see public/avatars/ATTRIBUTION.md), never database rows.

import { contrast } from './colours';

export interface Theme {
  hex: string;
  name: string;
}

/** Eight colours, each with white text at 4.5 : 1 or more. The first is the default. */
export const THEMES: Theme[] = [
  { hex: '#5B3FD1', name: 'Big Bucks purple' },
  { hex: '#8E24AA', name: 'Grape' },
  { hex: '#B0127A', name: 'Magenta' },
  { hex: '#3949AB', name: 'Blueberry' },
  { hex: '#0D47A1', name: 'Navy' },
  { hex: '#00695C', name: 'Teal' },
  { hex: '#1B5E20', name: 'Forest' },
  { hex: '#795548', name: 'Cocoa' },
];
export const DEFAULT_THEME = THEMES[0].hex;

export type AccessoryKey = 'party_hat' | 'grad_cap' | 'sunglasses' | 'top_hat' | 'bow' | 'crown';

/** Where things sit on an animal, as fractions of the picture (0 to 1). */
interface Spot {
  /** Centre, left to right. */
  x: number;
  /** For a hat: where its bottom edge sits. For glasses and the bow: their centre. */
  y: number;
  /** Width, as a fraction of the picture. */
  w: number;
  /** Tilt in degrees (side-on animals). */
  r?: number;
}

export interface Animal {
  key: string;
  name: string;
  /** The top of the head, between the ears, for the hats and the crown. */
  head: Spot;
  /** Across the eyes, for the sunglasses. */
  eyes: Spot;
  /** The side of the head, for the bow. */
  bow: Spot;
}

export const ANIMALS: Animal[] = [
  {
    key: 'fox',
    name: 'Fox',
    head: { x: 0.5, y: 0.3, w: 0.42 },
    eyes: { x: 0.5, y: 0.6, w: 0.62 },
    bow: { x: 0.8, y: 0.3, w: 0.32 },
  },
  {
    key: 'panda',
    name: 'Panda',
    head: { x: 0.5, y: 0.25, w: 0.44 },
    eyes: { x: 0.5, y: 0.53, w: 0.66 },
    bow: { x: 0.83, y: 0.24, w: 0.3 },
  },
  {
    key: 'koala',
    name: 'Koala',
    head: { x: 0.5, y: 0.2, w: 0.4 },
    eyes: { x: 0.5, y: 0.41, w: 0.58 },
    bow: { x: 0.82, y: 0.24, w: 0.3 },
  },
  {
    key: 'bunny',
    name: 'Bunny',
    head: { x: 0.5, y: 0.42, w: 0.36 },
    eyes: { x: 0.5, y: 0.66, w: 0.56 },
    bow: { x: 0.68, y: 0.3, w: 0.28 },
  },
  {
    key: 'cat',
    name: 'Cat',
    head: { x: 0.5, y: 0.26, w: 0.42 },
    eyes: { x: 0.5, y: 0.55, w: 0.62 },
    bow: { x: 0.8, y: 0.26, w: 0.3 },
  },
  {
    key: 'puppy',
    name: 'Puppy',
    head: { x: 0.5, y: 0.2, w: 0.42 },
    eyes: { x: 0.5, y: 0.5, w: 0.56 },
    bow: { x: 0.84, y: 0.2, w: 0.3 },
  },
  {
    key: 'owl',
    name: 'Owl',
    head: { x: 0.5, y: 0.14, w: 0.4 },
    eyes: { x: 0.5, y: 0.31, w: 0.6 },
    bow: { x: 0.78, y: 0.12, w: 0.28 },
  },
  {
    key: 'penguin',
    name: 'Penguin',
    head: { x: 0.52, y: 0.16, w: 0.32 },
    eyes: { x: 0.52, y: 0.3, w: 0.4 },
    bow: { x: 0.7, y: 0.14, w: 0.24 },
  },
  {
    key: 'unicorn',
    name: 'Unicorn',
    head: { x: 0.52, y: 0.32, w: 0.34, r: -10 },
    eyes: { x: 0.44, y: 0.5, w: 0.38, r: -10 },
    bow: { x: 0.72, y: 0.3, w: 0.26 },
  },
  {
    key: 'tiger',
    name: 'Tiger',
    head: { x: 0.5, y: 0.22, w: 0.42 },
    eyes: { x: 0.5, y: 0.52, w: 0.62 },
    bow: { x: 0.82, y: 0.2, w: 0.3 },
  },
  {
    key: 'frog',
    name: 'Frog',
    head: { x: 0.5, y: 0.14, w: 0.42 },
    eyes: { x: 0.5, y: 0.27, w: 0.76 },
    bow: { x: 0.84, y: 0.12, w: 0.28 },
  },
  {
    key: 'hedgehog',
    name: 'Hedgehog',
    // Side-on and small: everything bigger, on the top of its head (Dad's sheet review).
    head: { x: 0.25, y: 0.53, w: 0.38, r: -12 },
    eyes: { x: 0.26, y: 0.69, w: 0.4 },
    bow: { x: 0.31, y: 0.47, w: 0.3 },
  },
  {
    key: 'bear',
    name: 'Bear',
    head: { x: 0.5, y: 0.2, w: 0.42 },
    eyes: { x: 0.5, y: 0.5, w: 0.6 },
    bow: { x: 0.82, y: 0.18, w: 0.3 },
  },
  {
    key: 'hamster',
    name: 'Hamster',
    head: { x: 0.5, y: 0.24, w: 0.42 },
    eyes: { x: 0.5, y: 0.55, w: 0.6 },
    bow: { x: 0.82, y: 0.22, w: 0.3 },
  },
  {
    key: 'lion',
    name: 'Lion',
    head: { x: 0.5, y: 0.2, w: 0.42 },
    eyes: { x: 0.5, y: 0.5, w: 0.56 },
    bow: { x: 0.82, y: 0.2, w: 0.3 },
  },
  {
    key: 'moose',
    name: 'Moose',
    // Our mascot (Dad's sheet review): hats on top of its head in front of the antlers,
    // not squeezed between them; the bow by the ear at an antler's base.
    head: { x: 0.33, y: 0.45, w: 0.5, r: -6 },
    eyes: { x: 0.37, y: 0.57, w: 0.36 },
    bow: { x: 0.62, y: 0.42, w: 0.34 },
  },
];

export interface Accessory {
  key: AccessoryKey;
  name: string;
  /** Which spot on the animal it uses. */
  spot: 'head' | 'eyes' | 'bow';
  /** Its height as a fraction of its width (for placing a hat's bottom edge). */
  aspect: number;
  /** How to earn it, on the picker. */
  howTo: string;
}

export const ACCESSORIES: Accessory[] = [
  { key: 'party_hat', name: 'Party hat', spot: 'head', aspect: 1, howTo: 'Buy your first GIC.' },
  {
    key: 'grad_cap',
    name: 'Graduation cap',
    spot: 'head',
    aspect: 1,
    howTo: 'Keep a GIC until it finishes.',
  },
  {
    key: 'sunglasses',
    name: 'Sunglasses',
    spot: 'eyes',
    aspect: 1,
    howTo: 'Stay calm and keep a fund when it drops.',
  },
  {
    key: 'top_hat',
    name: 'Top hat',
    spot: 'head',
    aspect: 1,
    howTo: 'Build a GIC ladder (3 GICs, $10 or more each).',
  },
  { key: 'bow', name: 'Bow', spot: 'bow', aspect: 1, howTo: 'Earn your first dollar of interest.' },
  { key: 'crown', name: 'Crown', spot: 'head', aspect: 1, howTo: 'Reach your savings goal.' },
];

/**
 * How far down a hat's own picture its brim sits (0 to 1), so the brim, not the
 * bottom of the picture, rests on the head. Measured from the Fluent pictures.
 */
const BRIM: Record<AccessoryKey, number> = {
  party_hat: 0.92,
  grad_cap: 0.62,
  sunglasses: 0.5,
  top_hat: 0.9,
  bow: 0.5,
  crown: 0.85,
};

export function themeOf(hex: string | null | undefined): Theme {
  return THEMES.find((t) => t.hex === hex?.toUpperCase()) ?? THEMES[0];
}
export function animalOf(key: string | null | undefined): Animal | undefined {
  return ANIMALS.find((a) => a.key === key);
}
export function accessoryOf(key: string | null | undefined): Accessory | undefined {
  return ACCESSORIES.find((a) => a.key === key);
}

const base = () => import.meta.env.BASE_URL ?? '/';
export const animalSrc = (key: string) => `${base()}avatars/animals/${key}.svg`;
export const accessorySrc = (key: string) => `${base()}avatars/accessories/${key}.svg`;

/** White text on her colour, and her colour on the page: the two contrasts that matter. */
export function themeContrasts(hex: string): { onWhiteText: number; onPage: number } {
  return { onWhiteText: contrast('#FFFFFF', hex), onPage: contrast(hex, '#F7F5FF') };
}

/**
 * The part of each accessory picture you can actually see (measured from the SVGs: the
 * rest of its 32 × 32 square is transparent), as fractions of the picture.
 */
export const INK: Record<AccessoryKey, { x: number; y: number; w: number; h: number }> = {
  party_hat: { x: 0.125, y: 0.047, w: 0.75, h: 0.875 },
  grad_cap: { x: 0.063, y: 0.168, w: 0.867, h: 0.776 },
  sunglasses: { x: 0.061, y: 0.328, w: 0.878, h: 0.344 },
  top_hat: { x: 0.069, y: 0.123, w: 0.861, h: 0.813 },
  bow: { x: 0.063, y: 0.186, w: 0.873, h: 0.746 },
  crown: { x: 0.067, y: 0.183, w: 0.868, h: 0.711 },
};

/** The animal sits in the middle 74% of her circle (Avatar.css, .avatar__inner). */
export const INNER = 0.74;

/** Where an accessory goes, as CSS percentages of the animal's box. */
export interface Placement {
  left: number;
  top: number;
  width: number;
  rotate: number;
}

/**
 * Nothing may touch the circle's edge (Dad's sheet review): every corner of what you see
 * of an accessory stays within this distance of the circle's centre (its radius is 0.5).
 */
export const SAFE_RADIUS = 0.47;

/** The accessory at a given fraction of its planned size, its base kept in place. */
function placeAt(animal: Animal, acc: Accessory, scale: number): Placement {
  const s = animal[acc.spot];
  const width = s.w * scale;
  const height = width * acc.aspect;
  // A hat's brim stays on the head; glasses and the bow stay centred on their spot.
  const top = acc.spot === 'head' ? s.y - height * BRIM[acc.key] : s.y - height / 2;
  return { left: (s.x - width / 2) * 100, top: top * 100, width: width * 100, rotate: s.r ?? 0 };
}

/** The four corners of what you see of a placed accessory, in the circle's own terms. */
function cornersOf(p: Placement, acc: Accessory): [number, number][] {
  const left = p.left / 100;
  const top = p.top / 100;
  const width = p.width / 100;
  const height = width * acc.aspect;
  const ink = INK[acc.key];
  const x0 = left + width * ink.x;
  const y0 = top + height * ink.y;
  const x1 = x0 + width * ink.w;
  const y1 = y0 + height * ink.h;
  // Rotation is about the picture's bottom centre (transform-origin: 50% 100%).
  const cx = left + width / 2;
  const cy = top + height;
  const a = (p.rotate * Math.PI) / 180;
  const pad = (1 - INNER) / 2;
  return (
    [
      [x0, y0],
      [x1, y0],
      [x0, y1],
      [x1, y1],
    ] as [number, number][]
  ).map(([x, y]) => {
    const rx = cx + (x - cx) * Math.cos(a) - (y - cy) * Math.sin(a);
    const ry = cy + (x - cx) * Math.sin(a) + (y - cy) * Math.cos(a);
    return [pad + INNER * rx, pad + INNER * ry];
  });
}

const reach = (corners: [number, number][]) =>
  Math.max(...corners.map(([x, y]) => Math.hypot(x - 0.5, y - 0.5)));

/**
 * How big an accessory is drawn on an animal, as a fraction of its planned size: the
 * largest (up to the full size) that keeps it inside the circle.
 */
export function accessoryScale(animal: Animal, acc: Accessory): number {
  for (let scale = 1; scale > 0.5; scale -= 0.02)
    if (reach(cornersOf(placeAt(animal, acc, scale), acc)) <= SAFE_RADIUS) return scale;
  return 0.5;
}

/** Where an accessory's picture goes over an animal's picture (CSS percentages). */
export function placeAccessory(animal: Animal, acc: Accessory): Placement {
  return placeAt(animal, acc, accessoryScale(animal, acc));
}

/** The four corners of what you see of an accessory on an animal (for the test). */
export function accessoryCorners(animal: Animal, acc: Accessory): [number, number][] {
  return cornersOf(placeAccessory(animal, acc), acc);
}

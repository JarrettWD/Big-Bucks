// Her animal on a circle in her theme colour, wearing the accessory she picked
// (stage 10). Pictures are app files (public/avatars); where each accessory sits on
// each animal is in src/lib/look.ts.

import {
  accessoryOf,
  accessorySrc,
  animalOf,
  animalSrc,
  placeAccessory,
  themeOf,
} from '../lib/look';
import './Avatar.css';

export interface Look {
  /** Is "Make it yours" on for her? */
  on: boolean;
  badges_on: boolean;
  theme: string;
  animal: string | null;
  accessory: string | null;
}

export function Avatar({
  theme,
  animal,
  accessory,
  size = 56,
  label,
}: {
  theme: string;
  animal: string | null;
  accessory?: string | null;
  /** Diameter in CSS pixels (it grows with large text: see Avatar.css). */
  size?: number;
  /** What a screen reader says; empty when the words next to it already say it. */
  label?: string;
}) {
  const a = animalOf(animal);
  const acc = a ? accessoryOf(accessory) : undefined;
  const place = a && acc ? placeAccessory(a, acc) : null;
  const words =
    label ??
    (a ? `${a.name}${acc ? ` wearing a ${acc.name.toLowerCase()}` : ''}` : 'No animal picked yet');
  return (
    <span
      className="avatar"
      style={{ ['--avatar-size' as string]: `${size / 16}rem`, background: themeOf(theme).hex }}
      role={label === '' ? undefined : 'img'}
      aria-label={label === '' ? undefined : words}
      aria-hidden={label === '' ? true : undefined}
    >
      <span className="avatar__inner">
        {a ? (
          <img className="avatar__animal" src={animalSrc(a.key)} alt="" draggable={false} />
        ) : (
          <span className="avatar__none" aria-hidden="true">
            ?
          </span>
        )}
        {place && acc && (
          <img
            className="avatar__acc"
            src={accessorySrc(acc.key)}
            alt=""
            draggable={false}
            style={{
              left: `${place.left}%`,
              top: `${place.top}%`,
              width: `${place.width}%`,
              transform: place.rotate ? `rotate(${place.rotate}deg)` : undefined,
            }}
          />
        )}
      </span>
    </span>
  );
}

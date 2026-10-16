// Picking 1 to 5 stars for how much she wants it: five big buttons, read out as a
// radio group ("4 stars"), each at least 48 px.

import { useId } from 'react';
import { TEXT } from './wishText';

export function StarPicker({ value, onChange }: { value: number; onChange: (n: number) => void }) {
  const label = useId();
  return (
    <div className="field">
      <span id={label} className="field__label">
        {TEXT.stars}
      </span>
      <div className="wish__picker" role="radiogroup" aria-labelledby={label}>
        {[1, 2, 3, 4, 5].map((n) => (
          <button
            key={n}
            type="button"
            role="radio"
            aria-checked={value === n}
            aria-label={TEXT.starsLabel(n)}
            className={n <= value ? 'on' : ''}
            onClick={() => onChange(n)}
          >
            {n <= value ? '★' : '☆'}
          </button>
        ))}
      </div>
    </div>
  );
}

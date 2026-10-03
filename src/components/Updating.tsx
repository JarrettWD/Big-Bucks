// "Updating…": while the nightly check has found something to fix in her
// account, her figures are hidden rather than shown wrong. Calm, never alarming.

import type { ReactNode } from 'react';
import './Updating.css';

export function Updating({ updating, children }: { updating: boolean; children: ReactNode }) {
  if (!updating) return <>{children}</>;
  return (
    <div className="updating" role="status">
      <strong>Updating…</strong>
      <span>Your numbers are being double-checked. They'll be back soon.</span>
    </div>
  );
}

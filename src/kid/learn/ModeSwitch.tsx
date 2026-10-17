// Basic and detailed modes (stage 11): one button at the bottom of Home. Her choice is kept on
// her account (kid_set_view_mode), so every device she uses shows it. "View as" shows her mode
// and can't change it.

import { useState } from 'react';
import { supabase } from '../../lib/supabase';
import { useKid } from '../KidShell';
import { TEXT } from './learnText';
import './Learn.css';

export function ModeSwitch() {
  const { view, summary } = useKid();
  const [busy, setBusy] = useState(false);
  if (!summary.features.viewmodes) return null;
  const basic = summary.viewMode === 'basic';
  const go = async () => {
    if (view.viewing) return;
    setBusy(true);
    await supabase.rpc('kid_set_view_mode', { p_mode: basic ? 'detailed' : 'basic' });
    setBusy(false);
    summary.reload();
    window.scrollTo(0, 0);
  };
  return (
    <section className="mode" aria-label="How Home looks">
      <button
        type="button"
        className="btn btn--soft"
        onClick={go}
        disabled={busy}
        aria-disabled={view.viewing || undefined}
      >
        {basic ? TEXT.moreDetail : TEXT.simpler}
      </button>
      {!basic && <p className="muted mode__note">{TEXT.simplerNote}</p>}
    </section>
  );
}

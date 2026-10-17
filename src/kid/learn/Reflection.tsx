// "Why did you sell?" (stage 11): shown on Buy / Sell's Done step after a fund sale. It's a
// separate call (kid_save_reflection) made only after the sell request has succeeded, so
// skipping it, or a failed save, never touches the sale. Her words only, at most 300 letters.

import { useId, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { TEXT } from './learnText';
import './Learn.css';

export function Reflection({ requestId }: { requestId: number }) {
  const id = useId();
  const [text, setText] = useState('');
  const [state, setState] = useState<'open' | 'saving' | 'saved' | 'skipped'>('open');
  const [error, setError] = useState('');
  if (state === 'skipped') return null;
  if (state === 'saved')
    return (
      <p className="reflect" role="status">
        {TEXT.reflectSaved}
      </p>
    );
  const save = async () => {
    setState('saving');
    setError('');
    const { error: e } = await supabase.rpc('kid_save_reflection', {
      p_request_id: requestId,
      p_text: text,
    });
    if (e) {
      setError(e.message);
      setState('open');
    } else setState('saved');
  };
  return (
    <section className="reflect" aria-labelledby={`${id}-h`}>
      <h2 id={`${id}-h`}>{TEXT.reflectTitle}</h2>
      <p className="muted">
        {TEXT.reflectNote} {TEXT.reflectSkipNote}
      </p>
      <textarea
        id={`${id}-t`}
        aria-labelledby={`${id}-h`}
        maxLength={300}
        value={text}
        onChange={(e) => setText(e.target.value)}
      />
      <p className="muted" aria-live="polite">
        {300 - text.length} letters left
      </p>
      {error && (
        <p className="reflect__err" role="alert">
          {error}
        </p>
      )}
      <div className="reflect__buttons">
        <button type="button" className="btn" onClick={save} disabled={state === 'saving'}>
          {TEXT.reflectSave}
        </button>
        <button type="button" className="btn btn--soft" onClick={() => setState('skipped')}>
          {TEXT.reflectSkip}
        </button>
      </div>
    </section>
  );
}

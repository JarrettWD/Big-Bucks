// The **?** next to any money word: tap it for a short kid-friendly explanation
// from the glossary table (Dad edits the wording; nothing is hard-coded here).

import {
  createContext,
  useContext,
  useEffect,
  useId,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import { useAuth } from '../auth/AuthProvider';
import { supabase } from '../lib/supabase';
import './Glossary.css';

type Glossary = Map<string, { term: string; text: string }>;
const GlossaryContext = createContext<Glossary | null>(null);

// The glossary is readable only when signed in, so it loads (again) once someone is.
export function GlossaryProvider({ children }: { children: ReactNode }) {
  const userId = useAuth().session?.user.id;
  const [glossary, setGlossary] = useState<Glossary | null>(null);
  useEffect(() => {
    if (!userId) return;
    let alive = true;
    supabase
      .from('glossary')
      .select('term, kid_text')
      .then(({ data }) => {
        if (!alive || !data) return;
        setGlossary(
          new Map(data.map((g) => [g.term.toLowerCase(), { term: g.term, text: g.kid_text }])),
        );
      });
    return () => {
      alive = false;
    };
  }, [userId]);
  return <GlossaryContext.Provider value={glossary}>{children}</GlossaryContext.Provider>;
}

/** A small "?" that explains a glossary term. Renders nothing if the term isn't in the glossary. */
export function Explain({ term }: { term: string }) {
  const glossary = useContext(GlossaryContext);
  const [open, setOpen] = useState(false);
  const id = useId();
  const closeRef = useRef<HTMLButtonElement>(null);
  const entry = glossary?.get(term.toLowerCase());

  useEffect(() => {
    if (!open) return;
    closeRef.current?.focus();
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setOpen(false);
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open]);

  if (!entry) return null;
  return (
    <>
      <button
        type="button"
        className="explain"
        aria-label={`What does "${entry.term}" mean?`}
        aria-haspopup="dialog"
        onClick={() => setOpen(true)}
      >
        ?
      </button>
      {open && (
        <div className="explain__backdrop" onClick={() => setOpen(false)}>
          <div
            className="explain__card"
            role="dialog"
            aria-modal="true"
            aria-labelledby={`${id}-t`}
            onClick={(e) => e.stopPropagation()}
          >
            <h2 id={`${id}-t`}>{entry.term}</h2>
            <p>{entry.text}</p>
            <button
              ref={closeRef}
              type="button"
              className="explain__close"
              onClick={() => setOpen(false)}
            >
              Got it
            </button>
          </div>
        </div>
      )}
    </>
  );
}

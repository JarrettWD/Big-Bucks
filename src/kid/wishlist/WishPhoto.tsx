// A wish's photo. The wish list never carries photos; each thumbnail is loaded on its
// own (wish_photo), only once it scrolls into view, and kept for the visit, so opening
// the tab on mobile data stays light. The full photo loads only when she taps it.

import { useEffect, useRef, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { TEXT } from './wishText';

const cache = new Map<string, Promise<string | null>>();

/** One photo as a data: address, loaded once per item, version and size. */
function loadPhoto(id: string, version: string | null, size: 'thumb' | 'full') {
  const key = `${id}:${version ?? ''}:${size}`;
  let p = cache.get(key);
  if (!p) {
    p = Promise.resolve(supabase.rpc('wish_photo', { p_item: id, p_size: size })).then(
      ({ data, error }) => (error || !data ? null : `data:image/jpeg;base64,${data as string}`),
    );
    // A failed load is tried again next time.
    void p.then((v) => v === null && cache.delete(key));
    cache.set(key, p);
  }
  return p;
}

export function WishPhoto({
  id,
  version,
  name,
  className,
}: {
  id: string;
  version: string | null;
  name: string;
  className?: string;
}) {
  const box = useRef<HTMLButtonElement>(null);
  // Without IntersectionObserver (very old browsers), it loads straight away.
  const [near, setNear] = useState(() => !('IntersectionObserver' in window));
  const [thumb, setThumb] = useState<string | null>(null);
  const [full, setFull] = useState<string | null>(null);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    const el = box.current;
    if (!el || near) return;
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          setNear(true);
          io.disconnect();
        }
      },
      { rootMargin: '200px' },
    );
    io.observe(el);
    return () => io.disconnect();
  }, [near]);

  useEffect(() => {
    if (!near) return;
    let alive = true;
    void loadPhoto(id, version, 'thumb').then((v) => alive && setThumb(v));
    return () => {
      alive = false;
    };
  }, [near, id, version]);

  useEffect(() => {
    if (!open) return;
    let alive = true;
    void loadPhoto(id, version, 'full').then((v) => alive && setFull(v));
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setOpen(false);
    window.addEventListener('keydown', onKey);
    return () => {
      alive = false;
      window.removeEventListener('keydown', onKey);
    };
  }, [open, id, version]);

  return (
    <>
      <button
        ref={box}
        type="button"
        className={`wish-photo ${className ?? ''}`}
        onClick={() => setOpen(true)}
        aria-label={TEXT.photoAlt(name)}
      >
        {thumb && <img src={thumb} alt="" />}
      </button>
      {open && (
        <div
          className="wish-photo__full"
          role="dialog"
          aria-modal="true"
          aria-label={TEXT.photoAlt(name)}
        >
          <div className="wish-photo__frame">
            {full ? <img src={full} alt={TEXT.photoAlt(name)} /> : <p aria-busy="true">…</p>}
            <button type="button" className="btn" onClick={() => setOpen(false)} autoFocus>
              {TEXT.closePhoto}
            </button>
          </div>
        </div>
      )}
    </>
  );
}

// Dad's Wish lists (Stage 9): each girl's wish list and Done list, with the
// parent-only "Got it" marker, so Mom and Dad don't buy the same thing twice. She
// never sees the marker: it lives in wishlist_parent_marks, which no kid can read,
// and "View as" shows only what she sees. Marking is logged like every parent action.
// Everything comes from parent_wishlists(); photos load one at a time (WishPhoto).

import { useCallback, useEffect, useId, useState } from 'react';
import { formatDate } from '../../lib/format';
import { formatCents } from '../../lib/money';
import { supabase } from '../../lib/supabase';
import { WishPhoto } from '../../kid/wishlist/WishPhoto';
import {
  safeHref,
  siteName,
  type DoneWish,
  type Wish,
  type WishList,
} from '../../kid/wishlist/wishText';
import '../../kid/wishlist/WishList.css';
import './ParentWishlists.css';

type KidList = WishList & { account_id: string; name: string; is_test: boolean; enabled: boolean };

const PTEXT = {
  title: 'Wish lists',
  intro:
    'What each girl would love to have. "Got it" is only for Mom and Dad: she never sees it, and she can still save for or remove the item.',
  off: (name: string) => `The Wish List is off for ${name}.`,
  empty: (name: string) => `${name}'s wish list is empty.`,
  test: 'Test account',
  goal: 'Her goal',
  markGotIt: 'Mark "Got it"',
  gotIt: (on: string) => `✓ Got it · ${on}`,
  clear: 'Clear "Got it"',
  note: 'Note for the other parent (you can skip this)',
  save: 'Save "Got it"',
  cancel: 'Cancel',
  done: 'Done list',
  doneGot: 'She got it',
  doneRemoved: 'She removed it',
  openLink: 'Open link',
  outside: 'Opens outside Big Bucks.',
  loadError: "Couldn't load the wish lists. Please try again.",
  retry: 'Try again',
  stars: (n: number) => (n === 1 ? '1 star' : `${n} stars`),
};

export default function ParentWishlists() {
  const [kids, setKids] = useState<KidList[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const apply = useCallback((r: { data: unknown; error: { message: string } | null }) => {
    if (r.error) setError(r.error.message);
    else {
      setKids(r.data as KidList[]);
      setError(null);
    }
  }, []);
  const load = useCallback(async () => apply(await supabase.rpc('parent_wishlists')), [apply]);

  useEffect(() => {
    let alive = true;
    void Promise.resolve(supabase.rpc('parent_wishlists')).then((r) => alive && apply(r));
    return () => {
      alive = false;
    };
  }, [apply]);

  if (!kids)
    return (
      <div className="pwish">
        {error ? (
          <section className="pwish__card">
            <p>{PTEXT.loadError}</p>
            <button type="button" className="pwish__btn" onClick={() => void load()}>
              {PTEXT.retry}
            </button>
          </section>
        ) : (
          <p aria-busy="true">…</p>
        )}
      </div>
    );

  const real = kids.filter((k) => !k.is_test);
  const test = kids.filter((k) => k.is_test);
  return (
    <div className="pwish">
      <h1 className="pwish__title">{PTEXT.title}</h1>
      <p className="pwish__intro">{PTEXT.intro}</p>
      {error && (
        <p className="pwish__problem" role="alert">
          {error}
        </p>
      )}
      {[...real, ...test].map((k) => (
        <KidSection key={k.account_id} kid={k} reload={load} onError={setError} />
      ))}
    </div>
  );
}

function KidSection({
  kid,
  reload,
  onError,
}: {
  kid: KidList;
  reload: () => Promise<void>;
  onError: (e: string | null) => void;
}) {
  const id = useId();
  const year = Number(kid.today.slice(0, 4));
  return (
    <section className="pwish__card" aria-labelledby={id}>
      <h2 id={id} className="pwish__kid">
        {kid.name}
        {kid.is_test && <span className="pwish__test">{PTEXT.test}</span>}
      </h2>
      {!kid.enabled && <p className="pwish__muted">{PTEXT.off(kid.name)}</p>}
      {kid.items.length === 0 && kid.enabled && (
        <p className="pwish__muted">{PTEXT.empty(kid.name)}</p>
      )}
      <ol className="pwish__items">
        {kid.items.map((w) => (
          <li key={w.id}>
            <ItemRow w={w} year={year} reload={reload} onError={onError} />
          </li>
        ))}
      </ol>
      {kid.done.length > 0 && (
        <details className="pwish__done">
          <summary>
            {PTEXT.done} ({kid.done.length})
          </summary>
          <ul className="pwish__items">
            {kid.done.map((d) => (
              <li key={d.id}>
                <ItemRow w={d} year={year} reload={reload} onError={onError} />
              </li>
            ))}
          </ul>
        </details>
      )}
    </section>
  );
}

function ItemRow({
  w,
  year,
  reload,
  onError,
}: {
  w: Wish | DoneWish;
  year: number;
  reload: () => Promise<void>;
  onError: (e: string | null) => void;
}) {
  const [marking, setMarking] = useState(false);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const noteId = useId();
  const href = safeHref(w.link);
  const site = siteName(w.link);
  const isDone = w.status === 'got_it' || w.status === 'removed';

  const mark = async (gotIt: boolean) => {
    setBusy(true);
    const { error } = await supabase.rpc('parent_wishlist_mark', {
      p_item: w.id,
      p_got_it: gotIt,
      p_note: gotIt ? note : null,
    });
    setBusy(false);
    onError(error ? error.message : null);
    if (!error) {
      setMarking(false);
      setNote('');
    }
    await reload();
  };

  return (
    <article className={`pwish__item${w.marked ? ' pwish__item--marked' : ''}`}>
      <div className="pwish__row">
        {w.has_photo && (
          <WishPhoto id={w.id} version={w.photo_at} name={w.name} className="wish-photo--small" />
        )}
        <div className="pwish__what">
          <p className="pwish__name">
            {w.name}
            {w.status === 'goal' && <span className="pwish__goal">🎯 {PTEXT.goal}</span>}
          </p>
          <p className="pwish__muted">
            <span role="img" aria-label={PTEXT.stars(w.stars)}>
              {'★'.repeat(w.stars)}
            </span>
            {w.price_cents !== null && ` · ${formatCents(w.price_cents)}`}
            {isDone &&
              ` · ${w.status === 'got_it' ? PTEXT.doneGot : PTEXT.doneRemoved}${
                'done_on' in w && w.done_on ? `, ${formatDate(w.done_on, year)}` : ''
              }`}
          </p>
        </div>
      </div>
      {href && site && (
        <p className="pwish__link">
          <span className="pwish__site">{site}</span>{' '}
          <a href={href} target="_blank" rel="noopener noreferrer nofollow">
            {PTEXT.openLink} <span aria-hidden="true">↗</span>
          </a>{' '}
          <span className="pwish__muted">{PTEXT.outside}</span>
        </p>
      )}
      {w.marked ? (
        <div className="pwish__marked">
          <p>
            <strong>{PTEXT.gotIt(w.marked_on ? formatDate(w.marked_on, year) : '')}</strong>
            {w.mark_note && <> · {w.mark_note}</>}
          </p>
          <button
            type="button"
            className="pwish__btn pwish__btn--quiet"
            disabled={busy}
            onClick={() => void mark(false)}
          >
            {PTEXT.clear}
          </button>
        </div>
      ) : marking ? (
        <div className="pwish__mark-form">
          <label htmlFor={noteId}>{PTEXT.note}</label>
          <input
            id={noteId}
            value={note}
            maxLength={200}
            onChange={(e) => setNote(e.target.value)}
          />
          <div className="pwish__buttons">
            <button
              type="button"
              className="pwish__btn"
              disabled={busy}
              onClick={() => void mark(true)}
            >
              {PTEXT.save}
            </button>
            <button
              type="button"
              className="pwish__btn pwish__btn--quiet"
              onClick={() => setMarking(false)}
            >
              {PTEXT.cancel}
            </button>
          </div>
        </div>
      ) : (
        <button
          type="button"
          className="pwish__btn pwish__btn--quiet"
          onClick={() => setMarking(true)}
        >
          {PTEXT.markGotIt}
        </button>
      )}
    </article>
  );
}

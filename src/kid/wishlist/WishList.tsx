// The Wish List tab (Stage 9): the things she'd love to have, in her order, each with
// how close her total worth is and roughly when she could afford it; "Still want
// this?" from day 7 turns one into her savings goal; "I got this" and "Remove" move
// things to her Done list. Mom and Dad can see it all, and it says so at the top.
//
// The database does every check and every number (kid_wishlist and the wish_*
// functions); this screen only shows them and passes on what she taps. Photos load
// one at a time (WishPhoto). Wording: docs/MESSAGES.md §12.

import { useCallback, useEffect, useId, useRef, useState, type FormEvent } from 'react';
import { Navigate } from 'react-router-dom';
import { formatDate } from '../../lib/format';
import { formatCents } from '../../lib/money';
import { supabase } from '../../lib/supabase';
import { useKid } from '../KidShell';
import { parseAmount } from '../trade/moves';
import { preparePhoto, PhotoProblem } from './photo';
import { Progress } from './Progress';
import { StarPicker } from './StarPicker';
import { WishPhoto } from './WishPhoto';
import {
  DIP_LINE,
  goalLine,
  progressLine,
  projectionLine,
  safeHref,
  showDip,
  siteName,
  TEXT,
  type DoneWish,
  type Wish,
  type WishList as List,
} from './wishText';
import '../home/Home.css';
import '../trade/Trade.css';
import './WishList.css';

async function call(fn: string, args: Record<string, unknown>): Promise<string | null> {
  const { error } = await supabase.rpc(fn, args);
  return error ? error.message : null;
}

export default function WishList() {
  const { view, summary } = useKid();
  const [list, setList] = useState<List | null>(null);
  const [failed, setFailed] = useState(false);
  const [adding, setAdding] = useState(false);
  const [problem, setProblem] = useState('');

  const apply = useCallback((r: { data: unknown; error: unknown }) => {
    if (r.error) setFailed(true);
    else {
      setList(r.data as List);
      setFailed(false);
    }
  }, []);
  const fetchList = useCallback(
    async () => supabase.rpc('kid_wishlist', { p_account_id: view.accountId }),
    [view.accountId],
  );
  const load = useCallback(async () => apply(await fetchList()), [apply, fetchList]);

  useEffect(() => {
    let alive = true;
    void fetchList().then((r) => alive && apply(r));
    return () => {
      alive = false;
    };
  }, [fetchList, apply]);

  /** One action, then a fresh look. Its words (from the database) if it was refused. */
  const act = async (fn: string, args: Record<string, unknown>): Promise<string | null> => {
    setProblem('');
    const why = await call(fn, args);
    if (why) setProblem(why);
    await load();
    return why;
  };

  // Switched off for her (the tab is hidden then): back to Home.
  if (!summary.loading && !summary.wishlist) return <Navigate to={view.base} replace />;
  if (failed && !list)
    return (
      <div className="wish">
        <section className="card">
          <p>{TEXT.loadError}</p>
          <button type="button" className="btn" onClick={() => void load()}>
            {TEXT.retry}
          </button>
        </section>
      </div>
    );
  if (!list) return <div className="wish" aria-busy="true" aria-label="Loading your wish list" />;

  const goal = list.items.find((w) => w.status === 'goal') ?? null;
  const photosLeft = list.photos_max - list.photos_used;
  const move = (from: number, to: number) => {
    const ids = list.items.map((w) => w.id);
    const [id] = ids.splice(from, 1);
    ids.splice(to, 0, id);
    void act('wish_reorder', { p_items: ids });
  };

  return (
    <div className="wish">
      <header className="wish__head">
        <h1 className="wish__title">{TEXT.title} ⭐</h1>
        <p className="wish__see">
          <span aria-hidden="true">👀</span> {TEXT.seeLine}
        </p>
        <p className="muted">{TEXT.intro}</p>
      </header>

      {problem && (
        <p className="wish__problem" role="alert">
          {problem}
        </p>
      )}

      {adding ? (
        <WishForm
          title={TEXT.addTitle}
          photosLeft={photosLeft}
          photosMax={list.photos_max}
          onCancel={() => setAdding(false)}
          onSave={async (f) => {
            const { data, error } = await supabase.rpc('wish_add', {
              p_name: f.name,
              p_price_cents: f.priceCents,
              p_link: f.link,
              p_stars: f.stars,
            });
            if (error) return error.message;
            if (f.photo) {
              const why = await call('wish_set_photo', {
                p_item: data as string,
                p_photo: f.photo.photo,
                p_thumb: f.photo.thumb,
              });
              if (why) {
                await load();
                setAdding(false);
                setProblem(why);
                return null;
              }
            }
            await load();
            setAdding(false);
            return null;
          }}
        />
      ) : (
        <button type="button" className="btn btn--gold wish__add" onClick={() => setAdding(true)}>
          + {TEXT.add}
        </button>
      )}

      {list.items.length === 0 && !adding && <p className="card wish__empty">{TEXT.empty}</p>}

      <ol className="wish__list">
        {list.items.map((w, i) => (
          <li key={w.id}>
            <WishCard
              w={w}
              list={list}
              goal={goal}
              first={i === 0}
              last={i === list.items.length - 1}
              photosLeft={photosLeft}
              onUp={() => move(i, i - 1)}
              onDown={() => move(i, i + 1)}
              act={act}
              reload={load}
            />
          </li>
        ))}
      </ol>

      {list.done.length > 0 && <DoneList done={list.done} act={act} today={list.today} />}
    </div>
  );
}

// ---------------------------------------------------------------- one wish

function Stars({ n }: { n: number }) {
  return (
    <span className="wish__stars" role="img" aria-label={TEXT.starsLabel(n)}>
      {'★'.repeat(n)}
      <span className="wish__stars-off">{'☆'.repeat(5 - n)}</span>
    </span>
  );
}

function LinkRow({ link }: { link: string | null }) {
  const href = safeHref(link);
  const site = siteName(link);
  if (!href || !site) return null;
  return (
    <div className="wish__link">
      <span className="wish__site">{site}</span>
      <a
        className="btn btn--soft btn--small"
        href={href}
        target="_blank"
        rel="noopener noreferrer nofollow"
      >
        {TEXT.openLink} <span aria-hidden="true">↗</span>
      </a>
      <span className="wish__outside">{TEXT.linkOutside}</span>
    </div>
  );
}

type Asking = null | 'goal' | 'switch' | 'got_it' | 'removed';

function WishCard({
  w,
  list,
  goal,
  first,
  last,
  photosLeft,
  onUp,
  onDown,
  act,
  reload,
}: {
  w: Wish;
  list: List;
  goal: Wish | null;
  first: boolean;
  last: boolean;
  photosLeft: number;
  onUp: () => void;
  onDown: () => void;
  act: (fn: string, args: Record<string, unknown>) => Promise<string | null>;
  reload: () => Promise<void>;
}) {
  const [editing, setEditing] = useState(false);
  const [asking, setAsking] = useState<Asking>(null);
  const [busy, setBusy] = useState(false);
  // From day 7 "Still want this?" is open on the card; Not now folds it for this visit.
  const [notNow, setNotNow] = useState(false);
  const [photoOpen, setPhotoOpen] = useState(false);
  const titleId = useId();
  const isGoal = w.status === 'goal';
  const line = goalLine(w);
  const askGoal = asking === 'goal' || (line.kind === 'ready' && !notNow && asking === null);
  const projection = projectionLine(w, list.worth_cents);

  const run = async (fn: string, args: Record<string, unknown>) => {
    setBusy(true);
    await act(fn, args);
    setBusy(false);
    setAsking(null);
  };

  if (editing)
    return (
      <WishForm
        title={TEXT.editTitle}
        wish={w}
        photosLeft={photosLeft + (w.has_photo ? 1 : 0)}
        photosMax={list.photos_max}
        onCancel={() => setEditing(false)}
        onRemovePhoto={async () => {
          await act('wish_remove_photo', { p_item: w.id });
        }}
        onSave={async (f) => {
          const why = await call('wish_update', {
            p_item: w.id,
            p_name: f.name,
            p_price_cents: f.priceCents,
            p_link: f.link,
            p_stars: f.stars,
          });
          if (why) return why;
          if (f.photo) {
            const photoWhy = await call('wish_set_photo', {
              p_item: w.id,
              p_photo: f.photo.photo,
              p_thumb: f.photo.thumb,
            });
            if (photoWhy) return photoWhy;
          }
          await reload();
          setEditing(false);
          return null;
        }}
      />
    );

  return (
    <article
      className={`card wish-card${isGoal ? ' wish-card--goal' : ''}`}
      aria-labelledby={titleId}
    >
      <div className="wish-card__top">
        {w.has_photo && (
          <WishPhoto
            id={w.id}
            version={w.photo_at}
            name={w.name}
            open={photoOpen}
            onOpenChange={setPhotoOpen}
          />
        )}
        <div className="wish-card__what">
          {isGoal && <p className="wish__tag">🎯 {TEXT.goalTag}</p>}
          <h2 id={titleId} className="wish-card__name">
            {w.name}
          </h2>
          <p className="wish-card__meta">
            <Stars n={w.stars} />
            {w.price_cents !== null && (
              <span className="wish-card__price">{formatCents(w.price_cents)}</span>
            )}
          </p>
        </div>
      </div>

      {w.percent !== null && <Progress percent={w.percent} label={progressLine(w)} />}
      <p className="wish-card__line">{progressLine(w)}</p>
      {projection && <p className="muted">{projection}</p>}
      {showDip(list.funds_dipped, w) && <p className="wish__dip">{DIP_LINE}</p>}
      <LinkRow link={w.link} />

      {(line.kind === 'wait' || line.kind === 'needs_price') && (
        <p className="wish__goal-line">
          <span aria-hidden="true">🎯</span> {line.text}
        </p>
      )}

      {askGoal && (
        <div className="wish__ask" role="group" aria-label={TEXT.stillWant}>
          <p className="wish__ask-title">{TEXT.stillWant}</p>
          <p className="muted">{TEXT.stillWantWhy}</p>
          <button
            type="button"
            className="btn btn--gold"
            disabled={busy}
            onClick={() =>
              goal ? setAsking('switch') : void run('wish_make_goal', { p_item: w.id })
            }
          >
            {TEXT.yesGoal}
          </button>
          <button
            type="button"
            className="btn btn--soft"
            onClick={() => {
              setNotNow(true);
              setAsking(null);
            }}
          >
            {TEXT.notNow}
          </button>
        </div>
      )}
      {asking === 'switch' && goal && (
        <div className="wish__ask" role="group" aria-label={TEXT.switchTitle(goal.name, w.name)}>
          <p className="wish__ask-title">{TEXT.switchTitle(goal.name, w.name)}</p>
          <p className="muted">{TEXT.switchWhy(goal.name)}</p>
          <button
            type="button"
            className="btn btn--gold"
            disabled={busy}
            onClick={() => void run('wish_make_goal', { p_item: w.id, p_switch: true })}
          >
            {TEXT.yesSwitch}
          </button>
          <button
            type="button"
            className="btn btn--soft"
            onClick={() => {
              setNotNow(true);
              setAsking(null);
            }}
          >
            {TEXT.keepGoal}
          </button>
        </div>
      )}
      {(asking === 'got_it' || asking === 'removed') && (
        <div className="wish__ask" role="group">
          <p className="wish__ask-title">
            {asking === 'got_it' ? TEXT.gotItTitle(w.name) : TEXT.removeTitle(w.name)}
          </p>
          <p className="muted">{asking === 'got_it' ? TEXT.gotItWhy : TEXT.removeWhy}</p>
          <button
            type="button"
            className="btn"
            disabled={busy}
            onClick={() => void run('wish_done', { p_item: w.id, p_how: asking })}
          >
            {asking === 'got_it' ? TEXT.yesGotIt : TEXT.yesRemove}
          </button>
          <button type="button" className="btn btn--soft" onClick={() => setAsking(null)}>
            {TEXT.cancel}
          </button>
        </div>
      )}

      {asking === null && (
        <div className="wish-card__buttons">
          {line.kind === 'ready' && notNow && (
            <button
              type="button"
              className="btn btn--gold btn--small"
              onClick={() => setNotNow(false)}
            >
              🎯 {TEXT.makeGoal}
            </button>
          )}
          {isGoal && (
            <button
              type="button"
              className="btn btn--soft btn--small"
              disabled={busy}
              onClick={() => void run('wish_stop_goal', {})}
            >
              {TEXT.stopGoal}
            </button>
          )}
          <button
            type="button"
            className="btn btn--soft btn--small"
            onClick={() => setEditing(true)}
          >
            {TEXT.edit}
          </button>
          {w.has_photo && (
            <button
              type="button"
              className="btn btn--soft btn--small"
              onClick={() => setPhotoOpen(true)}
            >
              {TEXT.seePhoto}
            </button>
          )}
          <button
            type="button"
            className="btn btn--soft btn--small"
            onClick={() => setAsking('got_it')}
          >
            {TEXT.gotIt}
          </button>
          <button
            type="button"
            className="btn btn--soft btn--small"
            onClick={() => setAsking('removed')}
          >
            {TEXT.remove}
          </button>
          <span className="wish-card__order">
            <button
              type="button"
              className="btn btn--soft btn--small"
              disabled={first}
              onClick={onUp}
              aria-label={TEXT.moveUp(w.name)}
            >
              ▲
            </button>
            <button
              type="button"
              className="btn btn--soft btn--small"
              disabled={last}
              onClick={onDown}
              aria-label={TEXT.moveDown(w.name)}
            >
              ▼
            </button>
          </span>
        </div>
      )}
    </article>
  );
}

// ---------------------------------------------------------------- add / change

export interface WishFields {
  name: string;
  priceCents: string | null;
  link: string | null;
  stars: number;
  photo: { photo: string; thumb: string } | null;
}

function WishForm({
  title,
  wish,
  photosLeft,
  photosMax,
  onSave,
  onCancel,
  onRemovePhoto,
}: {
  title: string;
  wish?: Wish;
  photosLeft: number;
  photosMax: number;
  onSave: (f: WishFields) => Promise<string | null>;
  onCancel: () => void;
  onRemovePhoto?: () => Promise<void>;
}) {
  const [name, setName] = useState(wish?.name ?? '');
  const [price, setPrice] = useState(
    wish?.price_cents != null ? formatCents(wish.price_cents).slice(1) : '',
  );
  const [link, setLink] = useState(wish?.link ?? '');
  const [stars, setStars] = useState(wish?.stars ?? 3);
  const [photo, setPhoto] = useState<{ photo: string; thumb: string } | null>(null);
  const [photoBusy, setPhotoBusy] = useState(false);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const ids = { title: useId(), name: useId(), price: useId(), link: useId(), photo: useId() };
  const heading = useRef<HTMLHeadingElement>(null);
  const locked = wish?.status === 'goal';

  useEffect(() => heading.current?.focus(), []);

  const pick = async (file: File | undefined) => {
    if (!file) return;
    setError('');
    setPhotoBusy(true);
    try {
      setPhoto(await preparePhoto(file));
    } catch (e) {
      setError(
        e instanceof PhotoProblem
          ? e.message
          : "That photo didn't work. Try another one or a screenshot.",
      );
    } finally {
      setPhotoBusy(false);
    }
  };

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    const amount = parseAmount(price);
    if (amount.state === 'bad') {
      setError(amount.message);
      return;
    }
    setBusy(true);
    setError('');
    const why = await onSave({
      name,
      priceCents: amount.state === 'ok' ? amount.cents.toString() : null,
      link: link.trim() === '' ? null : link.trim(),
      stars,
      photo,
    });
    setBusy(false);
    if (why) setError(why);
  };

  return (
    <form className="card wish-form" aria-labelledby={ids.title} onSubmit={(e) => void submit(e)}>
      <h2 id={ids.title} className="card__title" tabIndex={-1} ref={heading}>
        {title}
      </h2>
      <div className="field">
        <label className="field__label" htmlFor={ids.name}>
          {TEXT.name}
        </label>
        <input
          id={ids.name}
          className="wish-form__input"
          value={name}
          maxLength={60}
          disabled={locked}
          onChange={(e) => setName(e.target.value)}
          autoComplete="off"
        />
        {locked && <span className="muted">{TEXT.nameLocked}</span>}
      </div>
      <div className="field">
        <label className="field__label" htmlFor={ids.price}>
          {TEXT.price}
        </label>
        <span className="field__money">
          <span aria-hidden="true">$</span>
          <input
            id={ids.price}
            className="field__input"
            inputMode="decimal"
            value={price}
            onChange={(e) => setPrice(e.target.value)}
            autoComplete="off"
          />
        </span>
      </div>
      <StarPicker value={stars} onChange={setStars} />
      <div className="field">
        <label className="field__label" htmlFor={ids.link}>
          {TEXT.link}
        </label>
        <input
          id={ids.link}
          className="wish-form__input"
          type="url"
          inputMode="url"
          value={link}
          maxLength={500}
          onChange={(e) => setLink(e.target.value)}
          autoComplete="off"
        />
        <span className="muted">{TEXT.linkHelp}</span>
      </div>
      <div className="field">
        <span className="field__label">{TEXT.photo}</span>
        {photosLeft <= 0 && !wish?.has_photo ? (
          <span className="muted">{TEXT.photosFull(photosMax)}</span>
        ) : (
          <label className="btn btn--soft wish-form__file" htmlFor={ids.photo}>
            📷 {photo || wish?.has_photo ? TEXT.changePhoto : TEXT.addPhoto}
            <input
              id={ids.photo}
              type="file"
              accept="image/*"
              className="visually-hidden"
              onChange={(e) => void pick(e.target.files?.[0])}
            />
          </label>
        )}
        {photoBusy && <span className="muted">{TEXT.photoBusy}</span>}
        {photo && (
          <img
            className="wish-form__preview"
            src={`data:image/jpeg;base64,${photo.thumb}`}
            alt=""
          />
        )}
        {wish?.has_photo && !photo && onRemovePhoto && (
          <button
            type="button"
            className="btn btn--soft btn--small"
            onClick={() => void onRemovePhoto()}
          >
            {TEXT.removePhoto}
          </button>
        )}
      </div>
      {error && (
        <p className="wish__problem" role="alert">
          {error}
        </p>
      )}
      <div className="wish-form__buttons">
        <button type="submit" className="btn btn--gold" disabled={busy || photoBusy}>
          {wish ? TEXT.save : TEXT.addIt}
        </button>
        <button type="button" className="btn btn--soft" onClick={onCancel}>
          {TEXT.cancel}
        </button>
      </div>
    </form>
  );
}

// ---------------------------------------------------------------- Done

function DoneList({
  done,
  act,
  today,
}: {
  done: DoneWish[];
  act: (fn: string, args: Record<string, unknown>) => Promise<string | null>;
  today: string;
}) {
  const year = Number(today.slice(0, 4));
  return (
    <section className="card wish-done" aria-labelledby="wish-done">
      <h2 id="wish-done" className="card__title">
        {TEXT.doneTitle}
      </h2>
      <p className="muted">{TEXT.doneIntro}</p>
      <ul className="wish-done__list">
        {done.map((d) => (
          <li key={d.id} className="wish-done__item">
            {d.has_photo && (
              <WishPhoto
                id={d.id}
                version={d.photo_at}
                name={d.name}
                className="wish-photo--small"
              />
            )}
            <span className="wish-done__name">{d.name}</span>
            <span className="wish-done__how">
              {d.status === 'got_it' ? `🎉 ${TEXT.doneGot}` : TEXT.doneRemoved}
              {d.done_on && ` · ${formatDate(d.done_on, year)}`}
            </span>
            {d.has_photo && (
              <button
                type="button"
                className="btn btn--soft btn--small"
                onClick={() => void act('wish_remove_photo', { p_item: d.id })}
              >
                {TEXT.removePhoto}
              </button>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}

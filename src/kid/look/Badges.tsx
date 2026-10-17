// Her badges (stage 10): the good decisions she has made, each with the day she made
// it and her animal wearing what it unlocked, then the rest, shown softly. No count,
// no progress bar, nothing timed: badges are for decisions, never activity.
// Wording: MESSAGES §13. Dad's "View as" reads the same (parent_view kid_badges).

import { useEffect, useState } from 'react';
import { Link, Navigate } from 'react-router-dom';
import { Avatar } from '../../components/Avatar';
import { Explain } from '../../components/Glossary';
import { supabase } from '../../lib/supabase';
import { useKid } from '../KidShell';
import { kidRpc } from '../kidView';
import { earnedOn, TEXT, type Badges as BadgeData } from './lookText';
import '../home/Home.css';
import './Look.css';

export default function Badges() {
  const { view, summary } = useKid();
  const look = summary.look;
  const [data, setData] = useState<BadgeData | null>(null);
  const [year, setYear] = useState<number | undefined>(undefined);
  const [msg, setMsg] = useState('');

  useEffect(() => {
    let live = true;
    void Promise.all([
      kidRpc<BadgeData>(view, 'kid_badges', { p_account_id: view.accountId }),
      kidRpc<string>(view, 'app_today'),
    ]).then(([b, today]) => {
      if (!live) return;
      setData(b.data);
      if (today.data) setYear(Number(today.data.slice(0, 4)));
    });
    return () => {
      live = false;
    };
  }, [view]);

  if (look && !look.badges_on) return <Navigate to=".." replace />;
  if (!data) return <div className="look" aria-busy="true" aria-label="Loading your badges" />;

  const kinds = new Map(data.kinds.map((k) => [k.key, k]));
  const have = new Set(data.earned.map((b) => b.badge));
  const todo = data.kinds.filter((k) => !have.has(k.key));
  const canWear = Boolean(look?.on) && !view.viewing;

  const wear = async (accessory: string) => {
    if (!look || !look.animal) return;
    const { error } = await supabase.rpc('kid_set_look', {
      p_theme: look.theme,
      p_animal: look.animal,
      p_accessory: accessory,
    });
    setMsg(error ? error.message : TEXT.wearing);
    summary.reload();
  };

  return (
    <div className="look">
      <h1 className="look__title">{TEXT.badgesTitle} 🏅</h1>
      <p className="muted">{TEXT.badgesIntro}</p>

      <section className="card" aria-labelledby="h-earned">
        <h2 id="h-earned" className="card__title">
          {TEXT.earnedHead}
        </h2>
        {data.earned.length === 0 ? (
          <p className="muted">{TEXT.noneYet}</p>
        ) : (
          <ul className="badges">
            {data.earned.map((b) => {
              const k = kinds.get(b.badge)!;
              return (
                <li key={b.badge} className="badge">
                  {look?.on ? (
                    <Avatar
                      theme={look.theme}
                      animal={look.animal}
                      accessory={b.accessory}
                      size={72}
                      label=""
                    />
                  ) : (
                    <span className="badge__emoji" aria-hidden="true">
                      {k.emoji}
                    </span>
                  )}
                  <div className="badge__words">
                    <h3 className="badge__name">
                      {look?.on && <span aria-hidden="true">{k.emoji} </span>}
                      {k.name}
                      {b.badge === 'gic_ladder' && <Explain term="GIC ladder" />}
                    </h3>
                    <p className="badge__date">
                      {earnedOn(b.earned_on, year ?? Number(b.earned_on.slice(0, 4)))}
                    </p>
                    <p className="badge__line">{k.earned_line}</p>
                    {canWear &&
                      (look!.accessory === b.accessory ? (
                        <p className="badge__wearing">{TEXT.wearing}</p>
                      ) : look!.animal ? (
                        <button
                          type="button"
                          className="btn btn--soft btn--small"
                          onClick={() => wear(b.accessory)}
                        >
                          {TEXT.wear}
                        </button>
                      ) : (
                        <p className="muted">
                          {TEXT.pickAnimalFirst}{' '}
                          <Link to={`${view.base}/look`}>{TEXT.lookTitle}</Link>
                        </p>
                      ))}
                  </div>
                </li>
              );
            })}
          </ul>
        )}
        <p className="look__msg" role="status">
          {msg}
        </p>
      </section>

      {todo.length > 0 && (
        <section className="card look__todo" aria-labelledby="h-todo">
          <h2 id="h-todo" className="card__title">
            {TEXT.todoHead}
          </h2>
          <ul className="badges">
            {todo.map((k) => (
              <li key={k.key} className="badge badge--todo">
                <span className="badge__emoji" aria-hidden="true">
                  {k.emoji}
                </span>
                <div className="badge__words">
                  <h3 className="badge__name">
                    {k.name}
                    {k.key === 'gic_ladder' && <Explain term="GIC ladder" />}
                  </h3>
                  <p className="badge__line">{k.todo_line}</p>
                </div>
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}

// A matured GIC: she chooses what happens next.
//   1. pick: keep it growing (renew), a different length (new term), or savings
//   2. (new term) how long
//   3. confirm: a plain summary, then "Yes, do it" calls choose_maturity
//   4. done
// It says plainly what happens if she doesn't choose by the date (the wording of
// the maturity notices, docs/MESSAGES.md §1 and §7). Every amount comes from the
// database; the interest preview is the database's gic_interest_cents.

import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { Explain } from '../components/Glossary';
import { formatDate, formatRate, termLabel, termWords } from '../lib/format';
import { formatCents } from '../lib/money';
import { supabase } from '../lib/supabase';
import { useKid } from './KidShell';
import { isWaiting, type Gic, type Rate } from './home/useHome';
import './home/Home.css';
import './GicChoice.css';

type Choice = 'renew' | 'new_term' | 'to_savings';
type Step = 'pick' | 'term' | 'confirm' | 'done';
const TERMS = [1, 3, 6, 9, 12, 24];

export default function GicChoice() {
  const { id } = useParams();
  const { summary } = useKid();
  const [gic, setGic] = useState<Gic | null | undefined>(undefined);
  const [rates, setRates] = useState<Rate[]>([]);
  const [year, setYear] = useState(0);
  const [step, setStep] = useState<Step>('pick');
  const [choice, setChoice] = useState<Choice | null>(null);
  const [term, setTerm] = useState<number | null>(null);
  const [preview, setPreview] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    let alive = true;
    Promise.all([
      supabase.from('gic_positions').select('*').eq('gic_id', Number(id)).maybeSingle(),
      supabase.rpc('current_rates'),
      supabase.rpc('app_today'),
    ]).then(([g, r, t]) => {
      if (!alive) return;
      setGic((g.data as Gic) ?? null);
      setRates((r.data ?? []) as Rate[]);
      setYear(Number(String(t.data ?? '').slice(0, 4)));
    });
    return () => {
      alive = false;
    };
  }, [id]);

  const gicRate = (t: number) => rates.find((r) => r.vehicle === 'gic' && r.gic_term === t);
  const savingsRate = rates.find((r) => r.vehicle === 'savings');
  const chosenTerm = choice === 'renew' ? (gic?.term_months ?? null) : term;
  const chosenRate = chosenTerm ? gicRate(chosenTerm) : undefined;

  // The database works out what the new GIC would earn.
  useEffect(() => {
    if (step !== 'confirm' || !gic || !chosenTerm || !chosenRate || choice === 'to_savings') return;
    let alive = true;
    supabase
      .rpc('gic_interest_cents', {
        p_principal_cents: gic.balance_cents,
        p_rate: chosenRate.rate,
        p_term_months: chosenTerm,
      })
      .then(({ data }) => alive && setPreview(data as number));
    return () => {
      alive = false;
    };
  }, [step, gic, chosenTerm, chosenRate, choice]);

  if (gic === undefined) return <div className="choice" aria-busy="true" aria-label="Loading" />;
  if (gic === null || (!isWaiting(gic) && step !== 'done'))
    return (
      <div className="choice">
        <section className="card">
          <h1 className="choice__title">Nothing to choose</h1>
          <p className="muted">There's nothing to choose for this GIC right now.</p>
          <Link className="btn" to="/kid">
            Back to Home
          </Link>
        </section>
      </div>
    );

  const balance = formatCents(gic.balance_cents);

  const submit = async () => {
    if (!choice) return;
    setBusy(true);
    setError('');
    const { error } = await supabase.rpc('choose_maturity', {
      p_gic_id: gic.gic_id,
      p_choice: choice,
      p_new_term: choice === 'new_term' ? term : null,
    });
    if (error) {
      setBusy(false);
      setError(error.message);
      return;
    }
    // Its "your GIC matured" notice has been answered now.
    const { data: n } = await supabase
      .from('notifications')
      .select('id')
      .eq('related_gic_id', gic.gic_id)
      .eq('type', 'gic_maturity')
      .is('read_at', null);
    if (n?.length) await supabase.rpc('mark_notices_read', { p_ids: n.map((x) => x.id) });
    setBusy(false);
    summary.reload();
    setStep('done');
  };

  return (
    <div className="choice">
      <section className="card choice__card" aria-labelledby="choice-title">
        {step !== 'done' && (
          <>
            <h1 id="choice-title" className="choice__title">
              <span aria-hidden="true">🎉 </span>Your GIC grew!
            </h1>
            <p className="choice__lead">
              Your {termLabel(gic.term_months)} GIC finished and earned{' '}
              <strong>{formatCents(gic.interest_at_maturity_cents)}</strong>. You now have{' '}
              <strong>{balance}</strong>.
            </p>
            <div className="choice__deadline">
              <p>
                <strong>Choose by {formatDate(gic.choose_by!, year)}.</strong> If you don't choose
                by then, your {balance} moves to savings, where it's safe and still earning
                interest.
              </p>
              {savingsRate && (
                <p>
                  Until you choose, it earns the savings rate ({formatRate(savingsRate.rate)} a
                  year).
                </p>
              )}
            </div>
          </>
        )}

        {step === 'pick' && (
          <fieldset className="options">
            <legend>What would you like to do?</legend>
            <OptionButton
              icon="🔁"
              title="Keep it growing"
              text={`Another ${termLabel(gic.term_months)} GIC${gicRate(gic.term_months) ? ` at ${formatRate(gicRate(gic.term_months)!.rate)}` : ''}${gicRate(gic.term_months)?.is_special ? ' (special rate!)' : ''}.`}
              onClick={() => {
                setChoice('renew');
                setStep('confirm');
              }}
            />
            <OptionButton
              icon="🗓️"
              title="Try a different length"
              text="Pick a shorter or longer GIC."
              onClick={() => {
                setChoice('new_term');
                setStep('term');
              }}
            />
            <OptionButton
              icon="🐷"
              title="Move it to savings"
              text={`Use it any time.${savingsRate ? ` Savings pays ${formatRate(savingsRate.rate)} a year.` : ''}`}
              onClick={() => {
                setChoice('to_savings');
                setStep('confirm');
              }}
            />
          </fieldset>
        )}

        {step === 'term' && (
          <fieldset className="options">
            <legend>
              How long? <Explain term="Term" />
            </legend>
            <div className="terms">
              {TERMS.map((t) => {
                const r = gicRate(t);
                return (
                  <button
                    key={t}
                    type="button"
                    className="term"
                    disabled={!r}
                    onClick={() => {
                      setTerm(t);
                      setStep('confirm');
                    }}
                  >
                    <span className="term__len">{termWords(t)}</span>
                    {r && <span className="term__rate">{formatRate(r.rate)}</span>}
                    {r?.is_special && <span className="term__special">Special!</span>}
                  </button>
                );
              })}
            </div>
            <button type="button" className="btn btn--soft" onClick={() => setStep('pick')}>
              Go back
            </button>
          </fieldset>
        )}

        {step === 'confirm' && choice && (
          <div className="confirm">
            {choice === 'to_savings' ? (
              <>
                <h2 className="confirm__q">Move {balance} to savings?</h2>
                <ul>
                  <li>You can use it any time.</li>
                  {savingsRate && (
                    <li>It earns {formatRate(savingsRate.rate)} a year in savings.</li>
                  )}
                </ul>
              </>
            ) : (
              chosenTerm &&
              chosenRate && (
                <>
                  <h2 className="confirm__q">
                    Put {balance} into a {termLabel(chosenTerm)} GIC at{' '}
                    {formatRate(chosenRate.rate)}?
                  </h2>
                  <ul>
                    <li>
                      It will earn <strong>{preview === null ? '…' : formatCents(preview)}</strong>{' '}
                      of interest.
                    </li>
                    <li>It's ready in {termWords(chosenTerm)}. Then you choose again.</li>
                    <li>
                      Taking it out early means losing that interest.{' '}
                      <Explain term="Breaking a GIC early" />
                    </li>
                  </ul>
                </>
              )
            )}
            {error && (
              <p className="choice__error" role="alert">
                {error}
              </p>
            )}
            <div className="confirm__buttons">
              <button type="button" className="btn" onClick={submit} disabled={busy}>
                {busy ? 'Working…' : 'Yes, do it'}
              </button>
              <button
                type="button"
                className="btn btn--soft"
                onClick={() => setStep(choice === 'new_term' ? 'term' : 'pick')}
                disabled={busy}
              >
                Go back
              </button>
            </div>
          </div>
        )}

        {step === 'done' && (
          <div className="done" role="status">
            <h1 id="choice-title" className="choice__title">
              <span aria-hidden="true">🎉 </span>Done!
            </h1>
            <p className="choice__lead">
              {choice === 'to_savings'
                ? `Your ${balance} is in savings.`
                : `Your ${balance} is growing in a new ${termLabel(chosenTerm ?? gic.term_months)} GIC. Great patience!`}
            </p>
            <Link className="btn" to="/kid">
              Back to Home
            </Link>
          </div>
        )}
      </section>
    </div>
  );
}

function OptionButton(p: { icon: string; title: string; text: string; onClick: () => void }) {
  return (
    <button type="button" className="option" onClick={p.onClick}>
      <span className="option__icon" aria-hidden="true">
        {p.icon}
      </span>
      <span className="option__text">
        <span className="option__title">{p.title}</span>
        <span className="option__desc">{p.text}</span>
      </span>
    </button>
  );
}

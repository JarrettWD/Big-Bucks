// Dad countersigns each girl's agreement here, on his own phone. He reads the copy
// she signed (frozen, numbers included), sees the notice she'll get and the log
// line (agreement_preview: the real action, rolled back, in_preview() on), then
// signs. The database checks everything again and logs it.

import { useEffect, useId, useRef, useState } from 'react';
import { Link, useLocation, useOutletContext } from 'react-router-dom';
import { AgreementView } from '../../kid/onboarding/AgreementView';
import type { AgreementDoc } from '../../kid/onboarding/onboardingText';
import { supabase } from '../../lib/supabase';
import { AGREE } from './approvalsText';
import type { InboxState } from '../useInbox';
import { waitingForDad, type KidAgreement } from './useAgreements';
import { useAuth } from '../../auth/AuthProvider';

interface Preview {
  problem: string | null;
  summary: string | null;
  notices: { title: string; body: string }[];
  copy: AgreementDoc | null;
}

/** The Approvals section. */
export function AgreementsToSign({
  items,
  test,
  heading: H,
}: {
  /** Agreements waiting for Dad, oldest signature first (parent_agreements). */
  items: KidAgreement[];
  test: boolean;
  heading: 'h2' | 'h3';
}) {
  const { reload } = useOutletContext<InboxState>();
  const [open, setOpen] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const { hash } = useLocation();
  // From the Dashboard's "Sign it now": straight to this section.
  useEffect(() => {
    if (hash === '#agreements' && !test) document.getElementById('agreements')?.scrollIntoView();
  }, [hash, test]);
  const waiting = items;
  return (
    <section
      className="appr__group"
      id={test ? 'agreements-test' : 'agreements'}
      aria-labelledby={`appr-agree-${test}`}
    >
      <H id={`appr-agree-${test}`}>
        {AGREE.title} <span className="appr__count">{waiting.length}</span>
      </H>
      {done && (
        <p className="appr__done" role="status">
          {done}
        </p>
      )}
      {waiting.length === 0 && <p className="appr__muted">{AGREE.empty}</p>}
      <ul className="appr__list">
        {waiting.map((k) => (
          <li key={k.account_id} className="appr__card">
            <div className="appr__head">
              <span className="appr__icon" aria-hidden="true">
                ✍️
              </span>
              <h3 className="appr__what">
                {AGREE.signedBy(k)}
                {k.is_test && <span className="appr__test">Test</span>}
                <span className="appr__kid">{AGREE.asked(k.signed_at ?? '')}</span>
              </h3>
            </div>
            {open === k.account_id ? (
              <Countersign
                k={k}
                onBack={() => setOpen(null)}
                onDone={async (text) => {
                  setOpen(null);
                  setDone(text);
                  await reload();
                }}
              />
            ) : (
              <div className="appr__actions">
                <button type="button" className="appr__btn" onClick={() => setOpen(k.account_id)}>
                  {AGREE.read}
                </button>
              </div>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}

function Countersign({
  k,
  onBack,
  onDone,
}: {
  k: KidAgreement;
  onBack: () => void;
  onDone: (text: string) => Promise<void>;
}) {
  const id = useId();
  const { profile } = useAuth();
  const headingRef = useRef<HTMLHeadingElement>(null);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState<string | null>(null);

  useEffect(() => {
    headingRef.current?.focus();
    let live = true;
    void supabase
      .rpc('agreement_preview', { p_account_id: k.account_id, p_version: k.signed_version })
      .then(({ data, error }) => {
        if (!live) return;
        setPreview(
          error
            ? { problem: error.message, summary: null, notices: [], copy: null }
            : (data as Preview),
        );
      });
    return () => {
      live = false;
    };
  }, [k.account_id, k.signed_version]);

  const sign = async () => {
    setSaving(true);
    setFailed(null);
    const { error } = await supabase.rpc('countersign_agreement', {
      p_account_id: k.account_id,
      p_version: k.signed_version,
    });
    if (error) {
      setSaving(false);
      setFailed(error.message);
      return;
    }
    // Who and when, from the database's own log row.
    const { data: who } = await supabase.rpc('parent_agreements');
    const row = ((who ?? []) as KidAgreement[]).find((x) => x.account_id === k.account_id);
    await onDone(
      AGREE.done(preview?.summary ?? '', profile?.displayName ?? 'you', row?.dad_signed_at ?? ''),
    );
  };

  const problem = failed ?? preview?.problem ?? null;
  return (
    <div className="appr__decide" role="group" aria-labelledby={`${id}-h`}>
      <h4 id={`${id}-h`} tabIndex={-1} ref={headingRef}>
        {AGREE.heading(k.kid)}
      </h4>
      <p>{AGREE.explain(k.kid)}</p>
      {preview === null ? (
        <p className="appr__muted">{AGREE.checking}</p>
      ) : (
        <>
          {preview.copy && (
            <div className="appr__agreement">
              <AgreementView doc={preview.copy} headingId={`${id}-doc`} />
            </div>
          )}
          {preview.summary && (
            <p>
              {AGREE.willRecord} <strong>{preview.summary}</strong>
            </p>
          )}
          <div className="appr__sees" aria-live="polite">
            <p className="appr__sees-label">{AGREE.sheSees(k.kid)}</p>
            {preview.notices.map((n) => (
              <div className="appr__notice" key={n.title}>
                <p className="appr__notice-title">{n.title}</p>
                <p className="appr__notice-body">{n.body}</p>
              </div>
            ))}
          </div>
        </>
      )}
      {problem && (
        <p className="appr__error" role="alert">
          {problem}
        </p>
      )}
      <div className="appr__actions">
        <button
          type="button"
          className="appr__btn"
          disabled={saving || preview === null || preview.problem !== null}
          onClick={() => void sign()}
        >
          {saving ? AGREE.saving : AGREE.yes(k.kid)}
        </button>
        <button
          type="button"
          className="appr__btn appr__btn--quiet"
          disabled={saving}
          onClick={onBack}
        >
          {AGREE.back}
        </button>
      </div>
    </div>
  );
}

/**
 * The top of the Dashboard (Dad, B4 review): a girl who has signed and is waiting
 * for his signature, in a highlight colour with one clear button. It goes away
 * once he has signed.
 */
export function AgreementsWaitingCard() {
  const { inbox } = useOutletContext<InboxState>();
  const waiting = (inbox?.agreements ?? []).filter(waitingForDad);
  if (waiting.length === 0) return null;
  return (
    <section className="dash__sign" aria-label={AGREE.title}>
      {waiting.map((k) => (
        <div key={k.account_id} className="dash__sign-card">
          <p className="dash__sign-text">
            ✍️ {AGREE.waitingCard(k.kid)}
            {k.is_test && <span className="appr__test">Test</span>}
          </p>
          <Link className="dash__sign-btn" to="/parent/approvals#agreements">
            {AGREE.signNow}
          </Link>
        </div>
      ))}
    </section>
  );
}

/** The dashboard's "Needs you" line for a girl who hasn't started setting up. */
export function AgreementsNeedYou() {
  const { inbox } = useOutletContext<InboxState>();
  const notStarted = (inbox?.agreements ?? []).filter(
    (k) => !k.is_test && !k.onboarding_done && k.signed_version === null,
  );
  if (notStarted.length === 0) return null;
  return (
    <div className="dash__agree">
      {notStarted.map((k) => (
        <p key={k.account_id} className="dash__muted">
          👋 {AGREE.notStarted(k.kid)}
        </p>
      ))}
    </div>
  );
}

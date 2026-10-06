// Dad countersigns each girl's agreement here, on his own phone. He reads the copy
// she signed (frozen, numbers included), sees the notice she'll get and the log
// line (agreement_preview: the real action, rolled back, in_preview() on), then
// signs. The database checks everything again and logs it.

import { useEffect, useId, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { AgreementView } from '../../kid/onboarding/AgreementView';
import type { AgreementDoc } from '../../kid/onboarding/onboardingText';
import { supabase } from '../../lib/supabase';
import { AGREE } from './approvalsText';
import { useAgreements, waitingForDad, type KidAgreement } from './useAgreements';
import { useAuth } from '../../auth/AuthProvider';

interface Preview {
  problem: string | null;
  summary: string | null;
  notices: { title: string; body: string }[];
  copy: AgreementDoc | null;
}

/** The Approvals section. */
export function AgreementsToSign() {
  const { list, reload } = useAgreements();
  const [open, setOpen] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  if (!list) return null;
  const waiting = list.filter(waitingForDad);
  return (
    <section className="appr__group" id="agreements" aria-labelledby="appr-agree">
      <h2 id="appr-agree">
        {AGREE.title} <span className="appr__count">{waiting.length}</span>
      </h2>
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
                <span className="appr__kid">{k.signed_at}</span>
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

/** The dashboard's "Needs you" lines: agreements to sign, and who hasn't set up yet. */
export function AgreementsNeedYou() {
  const { list } = useAgreements();
  if (!list) return null;
  const waiting = list.filter((k) => waitingForDad(k) && !k.is_test);
  const notStarted = list.filter(
    (k) => !k.is_test && !k.onboarding_done && k.signed_version === null,
  );
  if (waiting.length === 0 && notStarted.length === 0) return null;
  return (
    <div className="dash__agree">
      {waiting.length > 0 && (
        <p>
          ✍️ {AGREE.toSign(waiting.map((k) => k.kid))}{' '}
          <Link to="/parent/approvals#agreements">{AGREE.signNow}</Link>
        </p>
      )}
      {notStarted.map((k) => (
        <p key={k.account_id} className="dash__muted">
          👋 {AGREE.notStarted(k.kid)}
        </p>
      ))}
    </div>
  );
}

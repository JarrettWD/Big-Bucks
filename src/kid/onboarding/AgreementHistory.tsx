// On her "See all" page: every agreement she has signed, newest first, each
// opening to the rules exactly as she signed them.

import { useEffect, useId, useState } from 'react';
import { kidRpc, useKidView } from '../kidView';
import { AgreementView } from './AgreementView';
import { agreementLine, TEXT, type SignedAgreement } from './onboardingText';
import './Welcome.css';

export function AgreementHistory() {
  const view = useKidView();
  const [list, setList] = useState<SignedAgreement[] | null>(null);
  const [open, setOpen] = useState<number | null>(null);
  const id = useId();

  useEffect(() => {
    let live = true;
    void kidRpc<SignedAgreement[]>(view, 'my_agreements', { p_account_id: view.accountId }).then(
      ({ data }) => {
        if (live) setList(data ?? []);
      },
    );
    return () => {
      live = false;
    };
  }, [view]);

  return (
    <section className="card" id="agreement" aria-labelledby="h-agreement">
      <h2 id="h-agreement" className="card__title">
        {TEXT.historyTitle}
      </h2>
      {list === null ? null : list.length === 0 ? (
        <p className="muted">{TEXT.historyNone}</p>
      ) : (
        <ul className="activity">
          {list.map((a) => {
            const isOpen = open === a.version;
            return (
              <li key={a.version} className="activity__item">
                <button
                  type="button"
                  className="activity__row activity__row--move"
                  aria-expanded={isOpen}
                  aria-controls={`${id}-${a.version}`}
                  onClick={() => setOpen(isOpen ? null : a.version)}
                >
                  <span className="activity__icon" aria-hidden="true">
                    ✍️
                  </span>
                  <span className="activity__text">
                    <span className="activity__title">{agreementLine(a)}</span>
                  </span>
                </button>
                {isOpen && (
                  <div id={`${id}-${a.version}`} className="activity__more">
                    <AgreementView doc={a.copy} headingId={`${id}-${a.version}-h`} />
                    <p className="muted">{TEXT.afterSigning}</p>
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}

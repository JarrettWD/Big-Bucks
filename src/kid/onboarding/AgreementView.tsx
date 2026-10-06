// One version of the house rules, as she reads (or read) it: numbered rules with
// their icons, "New" and "Changed" marks, a ? on any word with an explanation,
// then Dad's promises. The numbers are already filled in by the database.

import { Explain } from '../../components/Glossary';
import { ruleSentence, TEXT, type AgreementDoc } from './onboardingText';

export function AgreementView({ doc, headingId }: { doc: AgreementDoc; headingId: string }) {
  return (
    <div className="agree">
      <h2 id={headingId} className="card__title">
        {doc.title}
      </h2>
      <p>{doc.intro}</p>
      <ol className="agree__rules">
        {doc.rules.map((r, i) => {
          const s = ruleSentence(r);
          return (
            <li key={i} className="agree__rule">
              <span className="agree__icon" aria-hidden="true">
                {r.icon}
              </span>
              <p className="agree__text">
                {r.mark && (
                  <span className={`agree__mark agree__mark--${r.mark}`}>
                    {r.mark === 'new' ? TEXT.newMark : TEXT.changedMark}
                  </span>
                )}
                <strong>{s.title}</strong>
                {s.rest}
                {r.glossary && (
                  <>
                    {' '}
                    <Explain term={r.glossary} />
                  </>
                )}
              </p>
            </li>
          );
        })}
      </ol>
      <div className="agree__promises">
        <h3>{TEXT.promises}</h3>
        <p>{doc.promises}</p>
      </div>
    </div>
  );
}

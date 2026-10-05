// What every Settings change shows: the preview's summary and the girls' notices,
// and the button that only works once the preview matches exactly what's typed.

import { TEXT, type ChangePreview } from './settingsText';

/** The summary, any facts line, and exactly what the girls will be told, and when. */
export function PreviewBox({
  id,
  current,
  problem,
  facts,
  extra,
  quiet = TEXT.noNotice,
}: {
  id: string;
  current: ChangePreview | null;
  problem: string | null;
  facts?: string | null;
  extra?: string | null;
  quiet?: string;
}) {
  return (
    <div className="set__sees" id={id} aria-live="polite">
      {problem ? (
        <p className="set__error" role="alert">
          {problem}
        </p>
      ) : current === null ? (
        <p className="set__muted">{TEXT.checking}</p>
      ) : (
        <>
          {facts && <p className="set__facts">{facts}</p>}
          {extra && <p className="set__muted">{extra}</p>}
          {current.summary && (
            <p className="set__record">
              {TEXT.willRecord} <strong>{current.summary}</strong>
            </p>
          )}
          {current.notices.length === 0 ? (
            <p className="set__muted">{quiet}</p>
          ) : (
            current.notices.map((n, i) => (
              <div key={i}>
                <p className="set__sees-label">{TEXT.theySee(n.on, n.kids)}</p>
                <div className="set__notice">
                  <p className="set__notice-title">{n.title}</p>
                  {n.body && <p>{n.body}</p>}
                </div>
              </div>
            ))
          )}
        </>
      )}
    </div>
  );
}

/** "Yes, …" (only once the preview matches what's typed) and "Back". */
export function ChangeActions({
  yes,
  blocked,
  saving,
  onYes,
  onBack,
}: {
  yes: string;
  blocked: boolean;
  saving: boolean;
  onYes: () => void;
  onBack: () => void;
}) {
  return (
    <div className="set__actions">
      <button type="button" className="set__btn" disabled={blocked || saving} onClick={onYes}>
        {saving ? TEXT.saving : yes}
      </button>
      <button type="button" className="set__btn set__btn--quiet" disabled={saving} onClick={onBack}>
        {TEXT.back}
      </button>
    </div>
  );
}

// Settings → Logins: reset a girl's PIN (Dad's decision, 2026-10-08). The database
// (reset_kid_pin) needs the authenticator code, logs it, tells her, signs her out on
// every device and makes a one-time code that is shown here once. At her next sign-in
// she types the code, then chooses a new PIN.

import { useCallback, useEffect, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { LOGINS, type KidLogin } from './settingsText';

export default function Logins() {
  const [kids, setKids] = useState<KidLogin[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [asking, setAsking] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [code, setCode] = useState<{ name: string; code: string } | null>(null);

  const load = useCallback(async () => {
    const { data, error: e } = await supabase.rpc('parent_logins');
    return e ? { kids: null, error: e.message } : { kids: data as KidLogin[], error: null };
  }, []);
  const show = useCallback((r: { kids: KidLogin[] | null; error: string | null }) => {
    if (r.error) setError(r.error);
    else setKids(r.kids);
  }, []);

  useEffect(() => {
    let alive = true;
    load().then((r) => {
      if (alive) show(r);
    });
    return () => {
      alive = false;
    };
  }, [load, show]);

  const reset = async (k: KidLogin) => {
    setBusy(true);
    setError(null);
    const { data, error: e } = await supabase.rpc('reset_kid_pin', { p_account_id: k.account_id });
    setBusy(false);
    setAsking(null);
    if (e) {
      setError(e.message);
      return;
    }
    setCode({ name: k.name, code: String(data) });
    show(await load());
  };

  return (
    <section className="set__card" id="set-logins" aria-labelledby="set-logins-h">
      <h2 id="set-logins-h">{LOGINS.title}</h2>
      <p className="set__muted">{LOGINS.intro}</p>
      {error && (
        <p className="set__error" role="alert">
          {error}
        </p>
      )}
      {code && (
        <div className="set__code" role="status">
          <p>{LOGINS.giveCode(code.name)}</p>
          <p className="set__code-digits" aria-label={code.code.split('').join(' ')}>
            {code.code.slice(0, 3)} {code.code.slice(3)}
          </p>
          <p className="set__muted">{LOGINS.codeOnce}</p>
          <button type="button" className="set__btn set__btn--quiet" onClick={() => setCode(null)}>
            {LOGINS.done}
          </button>
        </div>
      )}
      {kids && (
        <ul className="set__list">
          {kids.map((k) => (
            <li key={k.account_id} className="set__login">
              <div>
                <strong>{k.name}</strong>
                {k.is_test && <span className="set__muted"> {LOGINS.test}</span>}
                {k.reset_pending && <p className="set__muted">{LOGINS.pending(k.reset_expires)}</p>}
                {k.reset_expired && <p className="set__error">{LOGINS.expired}</p>}
              </div>
              {asking === k.account_id ? (
                <div className="set__confirm">
                  <p>{LOGINS.confirm(k.name)}</p>
                  <div className="set__actions">
                    <button
                      type="button"
                      className="set__btn"
                      disabled={busy}
                      onClick={() => reset(k)}
                    >
                      {LOGINS.yes(k.name)}
                    </button>
                    <button
                      type="button"
                      className="set__btn set__btn--quiet"
                      disabled={busy}
                      onClick={() => setAsking(null)}
                    >
                      {LOGINS.cancel}
                    </button>
                  </div>
                </div>
              ) : (
                <button
                  type="button"
                  className="set__btn set__btn--small"
                  onClick={() => {
                    setCode(null);
                    setAsking(k.account_id);
                  }}
                >
                  {LOGINS.reset(k.name)}
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

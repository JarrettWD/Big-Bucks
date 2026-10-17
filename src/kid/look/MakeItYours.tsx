// "Make it yours" (stage 10): her theme colour, her animal and, once she has earned
// them, something for it to wear. Opened by tapping her avatar on Home, and as
// onboarding step 2. The database checks every choice (kid_set_look: only colours
// and animals on the list, only accessories she has earned). Wording: MESSAGES §13.
// In Dad's "View as" it shows her choice, and nothing can be changed.

import { useEffect, useState } from 'react';
import { Navigate } from 'react-router-dom';
import { Avatar, type Look } from '../../components/Avatar';
import { ACCESSORIES, ANIMALS, DEFAULT_THEME, THEMES, themeOf } from '../../lib/look';
import { supabase } from '../../lib/supabase';
import { useKid } from '../KidShell';
import { kidRpc } from '../kidView';
import { TEXT, type Badges } from './lookText';
import '../home/Home.css';
import './Look.css';

export default function MakeItYours() {
  const { summary } = useKid();
  if (summary.look && !summary.look.on) return <Navigate to=".." replace />;
  return (
    <div className="look">
      <h1 className="look__title">{TEXT.lookTitle}</h1>
      <LookPicker />
    </div>
  );
}

/** The picker itself (also onboarding's "Make it yours" step, with its own button). */
export function LookPicker(props: { onSaved?: () => void; saveLabel?: string }) {
  const look = useKid().summary.look;
  // Starts from her saved look, so it waits for it on a fresh load.
  if (!look) return <div aria-busy="true" aria-label="Loading your look" />;
  return <PickerForm look={look} {...props} />;
}

function PickerForm({
  look,
  onSaved,
  saveLabel = TEXT.save,
}: {
  look: Look;
  onSaved?: () => void;
  saveLabel?: string;
}) {
  const { view, summary } = useKid();
  const [theme, setTheme] = useState(look.theme ?? DEFAULT_THEME);
  const [animal, setAnimal] = useState<string | null>(look.animal);
  const [accessory, setAccessory] = useState<string | null>(look.accessory);
  const [earned, setEarned] = useState<Set<string>>(new Set());
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  // Which accessories she has earned (her badges).
  useEffect(() => {
    if (!look.badges_on) return;
    let live = true;
    void kidRpc<Badges>(view, 'kid_badges', { p_account_id: view.accountId }).then(({ data }) => {
      if (live) setEarned(new Set((data?.earned ?? []).map((b) => b.accessory)));
    });
    return () => {
      live = false;
    };
  }, [view, look.badges_on]);

  const save = async () => {
    if (view.viewing) return;
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.rpc('kid_set_look', {
      p_theme: theme,
      p_animal: animal,
      p_accessory: accessory,
    });
    setBusy(false);
    if (error) {
      setMsg({ ok: false, text: error.message });
      return;
    }
    setMsg({ ok: true, text: TEXT.saved });
    summary.reload();
    onSaved?.();
  };

  const readOnly = view.viewing;
  const themeHex = themeOf(theme).hex;

  return (
    <div className="look__picker">
      <div className="look__preview">
        <Avatar theme={themeHex} animal={animal} accessory={accessory} size={112} />
      </div>

      <fieldset className="look__group">
        <legend className="look__legend">{TEXT.pickColour}</legend>
        <div className="look__swatches">
          {THEMES.map((t) => (
            <button
              key={t.hex}
              type="button"
              className="look__swatch"
              aria-pressed={themeHex === t.hex}
              aria-disabled={readOnly || undefined}
              onClick={() => !readOnly && setTheme(t.hex)}
            >
              <span className="look__dot" style={{ background: t.hex }} aria-hidden="true" />
              <span>{t.name}</span>
            </button>
          ))}
        </div>
      </fieldset>

      <fieldset className="look__group">
        <legend className="look__legend">{TEXT.pickAnimal}</legend>
        <div className="look__animals">
          {ANIMALS.map((a) => (
            <button
              key={a.key}
              type="button"
              className="look__animal"
              aria-pressed={animal === a.key}
              aria-disabled={readOnly || undefined}
              onClick={() => !readOnly && setAnimal(a.key)}
            >
              <Avatar theme={themeHex} animal={a.key} size={56} label="" />
              <span>{a.name}</span>
            </button>
          ))}
        </div>
      </fieldset>

      {look.badges_on && (
        <fieldset className="look__group">
          <legend className="look__legend">{TEXT.pickWear}</legend>
          <div className="look__wear">
            <button
              type="button"
              className="look__item"
              aria-pressed={accessory === null}
              aria-disabled={readOnly || undefined}
              onClick={() => !readOnly && setAccessory(null)}
            >
              <span className="look__item-name">{TEXT.none}</span>
            </button>
            {ACCESSORIES.map((acc) => {
              const has = earned.has(acc.key);
              return (
                <button
                  key={acc.key}
                  type="button"
                  className={has ? 'look__item' : 'look__item look__item--locked'}
                  aria-pressed={accessory === acc.key}
                  aria-disabled={readOnly || !has || undefined}
                  onClick={() => !readOnly && has && setAccessory(acc.key)}
                >
                  <img
                    className="look__item-pic"
                    src={`${import.meta.env.BASE_URL}avatars/accessories/${acc.key}.svg`}
                    alt=""
                  />
                  <span className="look__item-name">{acc.name}</span>
                  {!has && <span className="look__item-how">{acc.howTo}</span>}
                </button>
              );
            })}
          </div>
        </fieldset>
      )}

      <p className="muted">{TEXT.anyTime}</p>
      {readOnly ? (
        <p className="muted">{TEXT.viewing}</p>
      ) : (
        <button type="button" className="btn" onClick={save} disabled={busy || !animal}>
          {saveLabel}
        </button>
      )}
      <p className={msg?.ok ? 'look__msg' : 'look__msg look__msg--err'} role="status">
        {msg?.text ?? ''}
      </p>
    </div>
  );
}

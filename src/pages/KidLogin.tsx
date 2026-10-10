// The kid login: her username once, then a big PIN pad. The username is
// remembered on this device, so next time she only enters her PIN ("Not you?"
// switches). Five wrong PINs in a row mean a break (15 minutes, longer if it keeps
// happening; decided by the server), explained kindly. If Dad reset her PIN, she
// types his one-time code, then chooses a new PIN and types it again.

import { useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import { kidLogin, waitWords } from '../auth/kidLogin';
import { forgetKid, getRememberedKid, rememberKid } from '../auth/remember';
import './KidLogin.css';

type Message = { tone: 'oops' | 'rest'; text: string } | null;

export default function KidLogin() {
  const remembered = getRememberedKid();
  const [username, setUsername] = useState(remembered?.username ?? '');
  const [greeting, setGreeting] = useState(remembered?.displayName ?? remembered?.username ?? '');
  const [step, setStep] = useState<'username' | 'pin'>(remembered ? 'pin' : 'username');
  const [pin, setPin] = useState('');
  // Dad reset her PIN: his code, then her new PIN twice.
  const [phase, setPhase] = useState<'pin' | 'new' | 'again'>('pin');
  const [code, setCode] = useState('');
  const [firstNew, setFirstNew] = useState('');
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<Message>(null);

  const submitUsername = (e: FormEvent) => {
    e.preventDefault();
    const u = username.trim().toLowerCase();
    if (!u) return;
    setUsername(u);
    setGreeting(u);
    setMessage(null);
    setStep('pin');
  };

  const notYou = () => {
    forgetKid();
    setUsername('');
    setGreeting('');
    setPin('');
    setPhase('pin');
    setMessage(null);
    setStep('username');
  };

  const tryPin = async (full: string, newPin?: string) => {
    setBusy(true);
    const r = await kidLogin(username, full, newPin);
    setBusy(false);
    setPin('');
    if (r.kind !== 'new_pin_needed' && r.kind !== 'bad_new_pin') setPhase('pin');
    switch (r.kind) {
      case 'new_pin_needed':
        setCode(full);
        setPhase('new');
        return;
      case 'pin_set':
        setMessage({
          tone: 'oops',
          text: "Your new PIN is saved! Big Bucks couldn't sign you in just now. Try again in a minute with your new PIN.",
        });
        return;
      case 'bad_new_pin':
        setPhase('new');
        setMessage({ tone: 'oops', text: "Choose a new PIN that isn't Dad's code." });
        return;
      case 'ok':
        // Keep a name we already know; the app fills it in once it loads her profile.
        rememberKid({
          username,
          displayName: remembered?.username === username ? remembered.displayName : undefined,
        });
        return; // the app moves to her Home
      case 'wrong':
        setMessage({
          tone: 'oops',
          text:
            r.triesLeft <= 2
              ? `That PIN didn't match. ${r.triesLeft === 1 ? '1 more try' : `${r.triesLeft} more tries`} before a break.`
              : "That PIN didn't match. Try again.",
        });
        return;
      case 'locked': {
        setMessage({
          tone: 'rest',
          text: `Too many tries in a row, so this login is taking a break. Try again in ${waitWords(r.until)}, or ask Dad for help.`,
        });
        return;
      }
      case 'offline':
        setMessage({
          tone: 'oops',
          text: "Big Bucks couldn't reach the bank. Check your internet and try again.",
        });
        return;
      default:
        setMessage({
          tone: 'oops',
          text: 'Something went wrong on our side. Please try again in a minute.',
        });
    }
  };

  const press = (d: string) => {
    if (busy || pin.length >= 6) return;
    setMessage(null);
    const next = pin + d;
    setPin(next);
    if (next.length < 6) return;
    if (phase === 'pin') void tryPin(next);
    else if (phase === 'new') {
      setFirstNew(next);
      setPin('');
      setPhase('again');
    } else if (next === firstNew) void tryPin(code, next);
    else {
      setPin('');
      setPhase('new');
      setMessage({ tone: 'oops', text: "Those didn't match. Choose your new PIN again." });
    }
  };
  const back = () => !busy && setPin((p) => p.slice(0, -1));

  return (
    <main className="kid-login">
      <header className="kid-login__brand">
        <img
          src={`${import.meta.env.BASE_URL}icons/big-bucks-icon.svg`}
          alt=""
          width={72}
          height={72}
        />
        <h1>Big Bucks</h1>
        <p>Watch your bucks grow.</p>
      </header>

      {step === 'username' ? (
        <form className="kid-login__card" onSubmit={submitUsername}>
          <label htmlFor="kid-username" className="kid-login__label">
            Your username
          </label>
          <input
            id="kid-username"
            className="kid-login__input"
            autoComplete="username"
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            value={username}
            onChange={(e) => setUsername(e.target.value)}
          />
          <button className="kid-login__next" type="submit" disabled={!username.trim()}>
            Next
          </button>
        </form>
      ) : (
        <section className="kid-login__card" aria-labelledby="pin-title">
          <h2 id="pin-title" className="kid-login__hi">
            Hi, {greeting}!
          </h2>
          {phase === 'new' && (
            <p className="kid-login__note">Dad reset your PIN. Choose a new 6-digit PIN.</p>
          )}
          <p className="kid-login__label">
            {phase === 'pin'
              ? 'Enter your PIN'
              : phase === 'new'
                ? 'Your new PIN'
                : 'Type your new PIN again'}
          </p>
          <div
            className="kid-login__dots"
            role="img"
            aria-label={`${pin.length} of 6 digits entered`}
          >
            {Array.from({ length: 6 }, (_, i) => (
              <span key={i} className={i < pin.length ? 'is-filled' : ''} />
            ))}
          </div>
          {message && (
            <p className={`kid-login__msg kid-login__msg--${message.tone}`} role="alert">
              {message.text}
            </p>
          )}
          <div className="kid-login__pad">
            {['1', '2', '3', '4', '5', '6', '7', '8', '9'].map((d) => (
              <button key={d} type="button" onClick={() => press(d)} disabled={busy}>
                {d}
              </button>
            ))}
            <span />
            <button type="button" onClick={() => press('0')} disabled={busy}>
              0
            </button>
            <button type="button" onClick={back} disabled={busy} aria-label="Delete last digit">
              ⌫
            </button>
          </div>
          <button type="button" className="kid-login__link" onClick={notYou}>
            Not you?
          </button>
        </section>
      )}

      <Link className="kid-login__parent" to="/parent/login">
        Parent login
      </Link>
    </main>
  );
}

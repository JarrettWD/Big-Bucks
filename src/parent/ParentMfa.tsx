// Parent sign-in, step 2: the authenticator-app code (Supabase MFA, TOTP).
// The first time, it sets the authenticator up: scan the QR code (or type the
// key) into an authenticator app, then enter the 6-digit code it shows.

import { useEffect, useState, type FormEvent } from 'react';
import { Navigate, useNavigate } from 'react-router-dom';
import { isAuthSessionMissingError } from '@supabase/supabase-js';
import { useAuth } from '../auth/AuthProvider';
import { supabase } from '../lib/supabase';
import './Parent.css';

type Mode =
  | { kind: 'loading' }
  | { kind: 'verify'; factorId: string }
  | { kind: 'enrol'; factorId: string; qr: string; secret: string }
  | { kind: 'failed'; message: string };

export default function ParentMfa() {
  const navigate = useNavigate();
  const auth = useAuth();
  const [mode, setMode] = useState<Mode>({ kind: 'loading' });
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const isParentAal1 = auth.session && auth.profile?.role === 'parent' && auth.aal === 'aal1';

  useEffect(() => {
    if (!isParentAal1) return;
    let alive = true;
    (async () => {
      const { data, error } = await supabase.auth.mfa.listFactors();
      if (!alive) return;
      if (error)
        return setMode({
          kind: 'failed',
          message: 'Couldn’t check your authenticator. Try again.',
        });
      const verified = data.totp.find((f) => f.status === 'verified');
      if (verified) return setMode({ kind: 'verify', factorId: verified.id });
      // First time: clear any half-finished setup, then start a new one.
      for (const f of data.all.filter((f) => f.status === 'unverified'))
        await supabase.auth.mfa.unenroll({ factorId: f.id });
      const en = await supabase.auth.mfa.enroll({
        factorType: 'totp',
        friendlyName: `Big Bucks ${Date.now()}`,
      });
      if (!alive) return;
      if (en.error)
        return setMode({
          kind: 'failed',
          message: 'Couldn’t start the authenticator setup. Try again.',
        });
      setMode({
        kind: 'enrol',
        factorId: en.data.id,
        qr: en.data.totp.qr_code,
        secret: en.data.totp.secret,
      });
    })();
    return () => {
      alive = false;
    };
  }, [isParentAal1]);

  if (auth.loading) return null;
  if (!auth.session) return <Navigate to="/parent/login" replace />;
  if (auth.profile?.role !== 'parent') return <Navigate to="/" replace />;
  if (auth.aal === 'aal2') return <Navigate to="/parent" replace />;

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (mode.kind !== 'verify' && mode.kind !== 'enrol') return;
    setBusy(true);
    setError('');
    const { error } = await supabase.auth.mfa.challengeAndVerify({
      factorId: mode.factorId,
      code: code.trim(),
    });
    setBusy(false);
    if (error) {
      // Finishing the code step on one device ends the parent's other half-finished
      // sign-ins (Supabase's rule), so a new code here can never work.
      // supabase-js reports it as AuthSessionMissingError (no code); a verify racing
      // the deletion comes back as a server error.
      const ended =
        isAuthSessionMissingError(error) ||
        error.code === 'session_not_found' ||
        (error.status ?? 0) >= 500;
      setError(
        ended
          ? 'This sign-in has ended, maybe because you finished signing in on another device. Tap "Cancel and sign out", then sign in again.'
          : "That code didn't work. Codes change every 30 seconds, so use the newest one.",
      );
      setCode('');
      return;
    }
    await auth.refresh();
    navigate('/parent', { replace: true });
  };

  return (
    <main className="parent-auth">
      <h1>Big Bucks · Parent</h1>
      <form className="parent-auth__card" onSubmit={submit}>
        {mode.kind === 'loading' && <p>Checking your authenticator…</p>}
        {mode.kind === 'failed' && <p className="parent-auth__error">{mode.message}</p>}
        {mode.kind === 'enrol' && (
          <>
            <h2>Set up your authenticator</h2>
            <ol className="parent-auth__steps">
              <li>
                Open an authenticator app on your phone (for example Google Authenticator or
                Microsoft Authenticator).
              </li>
              <li>Add an account and scan this code, or type the key below.</li>
              <li>Enter the 6-digit code the app shows.</li>
            </ol>
            <img
              className="parent-auth__qr"
              src={mode.qr}
              alt="QR code for your authenticator app"
              width={200}
              height={200}
            />
            <p className="parent-auth__secret">
              Key: <code data-testid="totp-secret">{mode.secret}</code>
            </p>
          </>
        )}
        {mode.kind === 'verify' && <h2>Enter the code from your authenticator app</h2>}
        {(mode.kind === 'verify' || mode.kind === 'enrol') && (
          <>
            <label>
              6-digit code
              <input
                inputMode="numeric"
                autoComplete="one-time-code"
                pattern="\d{6}"
                maxLength={6}
                value={code}
                onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))}
                required
              />
            </label>
            {error && (
              <p className="parent-auth__error" role="alert">
                {error}
              </p>
            )}
            <button type="submit" disabled={busy || code.length !== 6}>
              {busy ? 'Checking…' : 'Sign in'}
            </button>
          </>
        )}
      </form>
      <button type="button" className="parent-auth__back" onClick={auth.signOut}>
        Cancel and sign out
      </button>
    </main>
  );
}

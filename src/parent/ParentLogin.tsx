// Parent sign-in, step 1: email and password. Step 2 (the authenticator code)
// is ParentMfa; parent screens need both.

import { useState, type FormEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useAuth } from '../auth/AuthProvider';
import { supabase } from '../lib/supabase';
import './Parent.css';

export default function ParentLogin() {
  const navigate = useNavigate();
  const { refresh } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError('');
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    setBusy(false);
    if (error) {
      setError(
        error.status === 400
          ? "That email and password don't match."
          : 'Sign-in failed. Please try again.',
      );
      return;
    }
    await refresh();
    navigate('/parent/mfa', { replace: true });
  };

  return (
    <main className="parent-auth">
      <h1>Big Bucks · Parent</h1>
      <form className="parent-auth__card" onSubmit={submit}>
        <label>
          Email
          <input
            type="email"
            autoComplete="username"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            required
          />
        </label>
        <label>
          Password
          <input
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
          />
        </label>
        {error && (
          <p className="parent-auth__error" role="alert">
            {error}
          </p>
        )}
        <button type="submit" disabled={busy}>
          {busy ? 'Signing in…' : 'Next'}
        </button>
      </form>
      <Link to="/login" className="parent-auth__back">
        Kid login
      </Link>
    </main>
  );
}

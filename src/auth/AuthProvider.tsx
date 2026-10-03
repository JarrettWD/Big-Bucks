// Who is signed in: the Supabase session, her profile (kid or parent), and for a
// parent whether the authenticator step is done (aal2). The screens use this to
// pick a shell; the database enforces the same rules on every call regardless.

import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from '../lib/supabase';

export interface Profile {
  userId: string;
  role: 'parent' | 'investor';
  username: string;
  displayName: string;
  accountId: string | null;
}

export interface AuthState {
  loading: boolean;
  session: Session | null;
  profile: Profile | null;
  /** 'aal2' once a parent has passed the authenticator step. */
  aal: 'aal1' | 'aal2' | null;
  refresh: () => Promise<void>;
  signOut: () => Promise<void>;
}

const AuthContext = createContext<AuthState | null>(null);

async function loadProfile(userId: string): Promise<Profile | null> {
  const { data, error } = await supabase
    .from('profiles')
    .select('user_id, role, username, display_name, account_id')
    .eq('user_id', userId)
    .maybeSingle();
  if (error || !data) return null;
  return {
    userId: data.user_id,
    role: data.role,
    username: data.username,
    displayName: data.display_name,
    accountId: data.account_id,
  };
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<Omit<AuthState, 'refresh' | 'signOut'>>({
    loading: true,
    session: null,
    profile: null,
    aal: null,
  });

  const load = useCallback(async (session: Session | null) => {
    if (!session) {
      setState({ loading: false, session: null, profile: null, aal: null });
      return;
    }
    const [profile, aal] = await Promise.all([
      loadProfile(session.user.id),
      supabase.auth.mfa.getAuthenticatorAssuranceLevel(),
    ]);
    setState({
      loading: false,
      session,
      profile,
      aal: (aal.data?.currentLevel as 'aal1' | 'aal2' | null) ?? 'aal1',
    });
  }, []);

  useEffect(() => {
    let alive = true;
    supabase.auth.getSession().then(({ data }) => {
      if (alive) void load(data.session);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
      // Run outside the auth lock (Supabase advises not awaiting inside this callback).
      if (event === 'INITIAL_SESSION') return;
      setTimeout(() => alive && load(session), 0);
    });
    return () => {
      alive = false;
      sub.subscription.unsubscribe();
    };
  }, [load]);

  const refresh = useCallback(async () => {
    const { data } = await supabase.auth.getSession();
    await load(data.session);
  }, [load]);

  const signOut = useCallback(async () => {
    // This device only: signing out on the tablet mustn't sign her out on her phone.
    await supabase.auth.signOut({ scope: 'local' });
    await load(null);
  }, [load]);

  return (
    <AuthContext.Provider value={{ ...state, refresh, signOut }}>{children}</AuthContext.Provider>
  );
}

// eslint-disable-next-line react-refresh/only-export-components
export function useAuth(): AuthState {
  const v = useContext(AuthContext);
  if (!v) throw new Error('useAuth must be inside <AuthProvider>');
  return v;
}

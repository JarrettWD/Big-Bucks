// "View as <kid>": Dad sees one girl's real Home, Graphs, history and notices,
// read-only, in her own app's frame. Every read goes through parent_view (parent
// only, authenticator code required); every action is switched off on screen and
// refused by the database. Viewing never marks her notices read.

import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import KidShell from '../../kid/KidShell';
import type { KidView } from '../../kid/kidView';
import { supabase } from '../../lib/supabase';
import '../Parent.css';

export default function ParentViewAs() {
  const { accountId = '' } = useParams();
  const [state, setState] = useState<{ id: string; view: KidView | null; error: string | null }>({
    id: '',
    view: null,
    error: null,
  });

  useEffect(() => {
    let alive = true;
    supabase
      .rpc('parent_view', { p_account: accountId, p_read: 'account' })
      .then(({ data, error }) => {
        if (!alive) return;
        setState({
          id: accountId,
          error: error ? error.message : null,
          view: error
            ? null
            : {
                accountId,
                name: (data as { name: string }).name,
                viewing: true,
                base: `/parent/view/${accountId}`,
              },
        });
      });
    return () => {
      alive = false;
    };
  }, [accountId]);

  if (state.id !== accountId)
    return <main className="splash" aria-busy="true" aria-label="Loading" />;
  if (!state.view)
    return (
      <main className="parent-auth">
        <div className="parent-auth__card">
          <p className="parent-auth__error" role="alert">
            Couldn&rsquo;t open her screens: {state.error}
          </p>
          <Link to="/parent">Back to the dashboard</Link>
        </div>
      </main>
    );
  return <KidShell viewing={state.view} />;
}

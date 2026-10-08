// The parent side's frame: its own header and routes. Reached only by a parent
// who has passed the authenticator step (the route guard in App.tsx); the
// database requires the same (aal2) for every parent read and action.
// Tabs: bottom of the screen on phones (Dad's main device), top from 720px.
// The Approvals count comes from parent_inbox() and parent_agreements(), shared with
// the Approvals screen and the Dashboard.

import { NavLink, Outlet } from 'react-router-dom';
import { useAuth } from '../auth/AuthProvider';
import { waitingForDad } from './approvals/useAgreements';
import { useInbox } from './useInbox';
import './Parent.css';

export default function ParentShell() {
  const { profile, signOut } = useAuth();
  const inbox = useInbox();
  // Deposits, withdrawals, questions, and (B4) agreements waiting for his signature.
  const waiting = inbox.inbox
    ? inbox.inbox.requests.length +
      inbox.inbox.questions.length +
      inbox.inbox.agreements.filter(waitingForDad).length
    : 0;
  return (
    <div className="parent">
      <header className="parent__top">
        <span className="parent__title">Big Bucks · {profile?.displayName}</span>
        <button type="button" onClick={signOut}>
          Sign out
        </button>
      </header>
      <nav className="parent__tabs" aria-label="Parent">
        <NavLink to="/parent" end>
          <span className="parent__tab-icon" aria-hidden="true">
            🏠
          </span>
          Dashboard
        </NavLink>
        <NavLink
          to="/parent/approvals"
          aria-label={waiting > 0 ? `Approvals, ${waiting} waiting` : 'Approvals'}
        >
          <span className="parent__tab-icon" aria-hidden="true">
            ✅
          </span>
          <span>
            Approvals
            {waiting > 0 && (
              <span className="parent__badge" aria-hidden="true">
                {waiting}
              </span>
            )}
          </span>
        </NavLink>
        <NavLink to="/parent/settings">
          <span className="parent__tab-icon" aria-hidden="true">
            ⚙️
          </span>
          Settings
        </NavLink>
      </nav>
      <main className="parent__main">
        <Outlet context={inbox} />
      </main>
    </div>
  );
}

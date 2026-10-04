// Routes and who may see them. The guards pick the right shell; the database
// enforces the same rules on every read and action, so a guard is never the
// only thing standing between a kid and parent data.
//
//   /login            kid login (username once, then PIN)
//   /kid/...          kid shell: Home, Graphs, Buy / Sell, Wish List, notices
//   /parent/login     parent email + password
//   /parent/mfa       parent authenticator code (set up the first time)
//   /parent/...       parent shell, only for a parent with the code done (aal2)

import { lazy, Suspense, type ReactNode } from 'react';
import { Navigate, Route, Routes, useParams } from 'react-router-dom';
import { AuthProvider, useAuth } from './auth/AuthProvider';
import { GlossaryProvider } from './components/Glossary';
import { OfflineScreen, useOnline } from './components/Offline';
import KidShell from './kid/KidShell';
import { KidWishList } from './kid/KidScreens';
import Notices from './kid/notices/Notices';
import Trade from './kid/trade/Trade';
import GicChoice from './kid/GicChoice';
import History from './kid/History';
import Home from './kid/home/Home';
import { supabaseConfigured } from './lib/supabase';
import KidLogin from './pages/KidLogin';
import ParentLogin from './parent/ParentLogin';
import ParentMfa from './parent/ParentMfa';
import ParentShell from './parent/ParentShell';
import Dashboard from './parent/dashboard/Dashboard';
import Settings from './parent/settings/Settings';
import ParentViewAs from './parent/viewas/ParentViewAs';
import Approvals from './parent/approvals/Approvals';

// Graphs carries Recharts, so it loads only when the Graphs tab opens.
const Graphs = lazy(() => import('./kid/graphs/Graphs'));

function Splash() {
  return <main className="splash" aria-busy="true" aria-label="Loading" />;
}

function NotSetUp({ text }: { text: string }) {
  const { signOut } = useAuth();
  return (
    <main className="splash splash--msg">
      <p>{text}</p>
      <button type="button" onClick={signOut}>
        Sign out
      </button>
    </main>
  );
}

/** Where a signed-in person belongs. */
function home(role: 'parent' | 'investor' | undefined, aal: string | null): string {
  if (role === 'investor') return '/kid';
  if (role === 'parent') return aal === 'aal2' ? '/parent' : '/parent/mfa';
  return '/login';
}

function RequireKid({ children }: { children: ReactNode }) {
  const { loading, session, profile, aal } = useAuth();
  if (loading) return <Splash />;
  if (!session) return <Navigate to="/login" replace />;
  if (!profile) return <NotSetUp text="This login isn't set up for Big Bucks yet. Ask Dad." />;
  if (profile.role !== 'investor') return <Navigate to={home(profile.role, aal)} replace />;
  return <>{children}</>;
}

function RequireParent({ children }: { children: ReactNode }) {
  const { loading, session, profile, aal } = useAuth();
  if (loading) return <Splash />;
  if (!session) return <Navigate to="/parent/login" replace />;
  if (!profile) return <NotSetUp text="This login isn't set up for Big Bucks." />;
  // A kid session never reaches the parent screens: back to her own Home.
  if (profile.role !== 'parent') return <Navigate to="/kid" replace />;
  if (aal !== 'aal2') return <Navigate to="/parent/mfa" replace />;
  return <>{children}</>;
}

/** Sign-in pages: someone already signed in goes to their own home instead (so a
 *  kid session never even sees the parent login; sign out first to switch). */
function SignedOutOnly({ children }: { children: ReactNode }) {
  const { loading, session, profile, aal } = useAuth();
  if (loading) return <Splash />;
  if (session && profile) return <Navigate to={home(profile.role, aal)} replace />;
  return <>{children}</>;
}

/** Any other address inside "View as <kid>" goes to her Home (Buy / Sell isn't offered). */
function ToHerHome() {
  const { accountId } = useParams();
  return <Navigate to={`/parent/view/${accountId}`} replace />;
}

function Root() {
  const { loading, session, profile, aal } = useAuth();
  if (loading) return <Splash />;
  return <Navigate to={session && profile ? home(profile.role, aal) : '/login'} replace />;
}

export default function App() {
  const online = useOnline();
  if (!online) return <OfflineScreen />;
  if (!supabaseConfigured)
    return (
      <main className="splash splash--msg">
        <p>
          Big Bucks isn't connected to its database yet. Run "npm run demo" (or "npm run
          setup-account") first.
        </p>
      </main>
    );
  return (
    <AuthProvider>
      <GlossaryProvider>
        <Routes>
          <Route path="/" element={<Root />} />
          <Route
            path="/login"
            element={
              <SignedOutOnly>
                <KidLogin />
              </SignedOutOnly>
            }
          />
          <Route
            path="/kid"
            element={
              <RequireKid>
                <KidShell />
              </RequireKid>
            }
          >
            <Route index element={<Home />} />
            <Route path="history" element={<History />} />
            <Route path="gic/:id" element={<GicChoice />} />
            <Route
              path="graphs"
              element={
                <Suspense fallback={<p className="muted">Loading the graphs…</p>}>
                  <Graphs />
                </Suspense>
              }
            />
            <Route path="trade" element={<Trade />} />
            <Route path="wishlist" element={<KidWishList />} />
            <Route path="notices" element={<Notices />} />
          </Route>
          <Route
            path="/parent/login"
            element={
              <SignedOutOnly>
                <ParentLogin />
              </SignedOutOnly>
            }
          />
          <Route path="/parent/mfa" element={<ParentMfa />} />
          {/* Dad's read-only "View as <kid>": her screens, in her own app's frame. */}
          <Route
            path="/parent/view/:accountId"
            element={
              <RequireParent>
                <ParentViewAs />
              </RequireParent>
            }
          >
            <Route index element={<Home />} />
            <Route path="history" element={<History />} />
            <Route
              path="graphs"
              element={
                <Suspense fallback={<p className="muted">Loading the graphs…</p>}>
                  <Graphs />
                </Suspense>
              }
            />
            <Route path="notices" element={<Notices />} />
            <Route path="*" element={<ToHerHome />} />
          </Route>
          <Route
            path="/parent"
            element={
              <RequireParent>
                <ParentShell />
              </RequireParent>
            }
          >
            <Route index element={<Dashboard />} />
            <Route path="approvals" element={<Approvals />} />
            <Route path="settings" element={<Settings />} />
            <Route path="*" element={<Navigate to="/parent" replace />} />
          </Route>
          <Route path="*" element={<Root />} />
        </Routes>
      </GlossaryProvider>
    </AuthProvider>
  );
}

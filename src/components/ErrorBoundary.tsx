// The app-wide safety net (Dad, 2026-10-19): if a screen ever throws while drawing, show a
// friendly message with a way back instead of a blank purple page. It never touches money:
// it only replaces what's drawn. It resets when the page changes (see ScreenBoundary).

import { Component, type ErrorInfo, type ReactNode } from 'react';
import { useLocation } from 'react-router-dom';
import { BOUNDARY_TEXT } from './errorText';
import './ErrorBoundary.css';

class Boundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false };

  static getDerivedStateFromError(): { failed: boolean } {
    return { failed: true };
  }

  componentDidCatch(error: Error, info: ErrorInfo): void {
    // For the browser's console only (nothing is sent anywhere).
    console.error('Screen error:', error, info.componentStack);
  }

  render(): ReactNode {
    if (!this.state.failed) return this.props.children;
    return (
      <main className="oops" role="alert">
        <h1 className="oops__title">{BOUNDARY_TEXT.title}</h1>
        <p>{BOUNDARY_TEXT.body}</p>
        <div className="oops__buttons">
          <button type="button" className="oops__btn" onClick={() => window.history.back()}>
            {BOUNDARY_TEXT.back}
          </button>
          <a className="oops__btn oops__btn--soft" href={import.meta.env.BASE_URL}>
            {BOUNDARY_TEXT.home}
          </a>
        </div>
      </main>
    );
  }
}

/** One boundary per page: moving to another page starts fresh. */
export function ScreenBoundary({ children }: { children: ReactNode }) {
  const { pathname } = useLocation();
  return <Boundary key={pathname}>{children}</Boundary>;
}

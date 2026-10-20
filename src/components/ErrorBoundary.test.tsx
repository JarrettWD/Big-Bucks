// Dad, 2026-10-19: a screen that throws must show a friendly message with a way back, never a
// blank page; and moving to another page starts fresh.
import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi } from 'vitest';
import { ScreenBoundary } from './ErrorBoundary';
import { BOUNDARY_TEXT, isParentPath } from './errorText';

function Broken(): never {
  throw new Error('Not a whole number of cents: "1,000"');
}

describe('the app-wide safety net', () => {
  it('shows a friendly message and a way back when a screen throws', () => {
    const quiet = vi.spyOn(console, 'error').mockImplementation(() => {});
    render(
      <MemoryRouter>
        <ScreenBoundary>
          <Broken />
        </ScreenBoundary>
      </MemoryRouter>,
    );
    expect(screen.getByRole('alert')).toBeTruthy();
    expect(screen.getByRole('heading', { name: BOUNDARY_TEXT.title })).toBeTruthy();
    expect(screen.getByRole('button', { name: BOUNDARY_TEXT.back })).toBeTruthy();
    expect(screen.getByRole('link', { name: BOUNDARY_TEXT.home })).toBeTruthy();
    quiet.mockRestore();
  });
  it('tells a kid to tell Mom or Dad, and tells Dad to tell Buck', () => {
    const quiet = vi.spyOn(console, 'error').mockImplementation(() => {});
    const at = (path: string) =>
      render(
        <MemoryRouter initialEntries={[path]}>
          <ScreenBoundary>
            <Broken />
          </ScreenBoundary>
        </MemoryRouter>,
      );
    const kid = at('/kid/trade');
    expect(screen.getByText(BOUNDARY_TEXT.kidBody)).toBeTruthy();
    expect(BOUNDARY_TEXT.kidBody).toContain('tell Mom or Dad what you were doing');
    kid.unmount();
    for (const path of ['/parent/settings', '/parent/view/abc/graphs', '/parent']) {
      const parent = at(path);
      expect(screen.getByText(BOUNDARY_TEXT.parentBody)).toBeTruthy();
      parent.unmount();
    }
    expect(BOUNDARY_TEXT.parentBody).toContain('note what you were doing and tell Buck');
    expect(isParentPath('/parents-day')).toBe(false);
    quiet.mockRestore();
  });
  it('shows the screen as normal when nothing goes wrong', () => {
    render(
      <MemoryRouter>
        <ScreenBoundary>
          <p>All good</p>
        </ScreenBoundary>
      </MemoryRouter>,
    );
    expect(screen.getByText('All good')).toBeTruthy();
    expect(screen.queryByRole('alert')).toBeNull();
  });
});

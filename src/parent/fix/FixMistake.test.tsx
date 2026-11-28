// The Fix a close focus bug (Dad, 2026-11-21), checked on Fix a mistake's amount box too: its form
// is drawn from the latest preview, so a preview call that failed outright (no kid in it) used to
// take the boxes away mid-typing. Typed one key at a time, the box stays the same and focused.
import { act, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const rpc = vi.fn();
vi.mock('../../lib/supabase', () => ({ supabase: { rpc: (...a: unknown[]) => rpc(...a) } }));

import FixMistake from './FixMistake';
import { TEXT } from './fixText';

const result = {
  problem: null,
  warning: null,
  limit_cents: null,
  line_left_cents: null,
  counts_as: null,
  needs_retype: false,
  kid: 'Test kid',
  line: null,
  question: null,
  savings_cents: 9518,
  held_cents: 0,
  free_cents: 9518,
  check_over_cents: null,
  cents: null,
  typed: null,
  rounded: false,
  needs_check: false,
  savings_after_cents: null,
  free_after_cents: null,
  summary: null,
  notices: [],
};

const settle = (ms: number) =>
  act(async () => {
    await vi.advanceTimersByTimeAsync(ms);
  });

beforeEach(() => {
  vi.useFakeTimers();
  rpc.mockReset();
});
afterEach(() => {
  vi.useRealTimers();
});

describe('Fix a mistake: typing the amount', () => {
  it('keeps the same box, focused, digit by digit, even when a preview fails', async () => {
    let previews = 0;
    rpc.mockImplementation(async (fn: string) => {
      if (fn === 'parent_corrections') return { data: [], error: null };
      previews += 1;
      if (previews === 3) return { data: null, error: { message: 'Something went wrong.' } };
      return { data: result, error: null };
    });
    render(
      <MemoryRouter initialEntries={['/parent/fix/acct-1']}>
        <Routes>
          <Route path="/parent/fix/:accountId" element={<FixMistake />} />
        </Routes>
      </MemoryRouter>,
    );
    await settle(500);
    fireEvent.click(screen.getByLabelText(TEXT.add));
    await settle(450);

    const box = screen.getByLabelText(TEXT.amount) as HTMLInputElement;
    box.focus();
    const amount = '12.50';
    for (let i = 1; i <= amount.length; i++) {
      fireEvent.change(box, { target: { value: amount.slice(0, i) } });
      await settle(i % 2 === 0 ? 450 : 100);
      expect(screen.getByLabelText(TEXT.amount)).toBe(box);
      expect(document.activeElement).toBe(box);
      expect(box.value).toBe(amount.slice(0, i));
    }
    expect(previews).toBeGreaterThanOrEqual(3);
  });
});

// Dad, 2026-11-21 (applying the 23 fixes): "The official close" box lost focus after every
// keystroke, on his phone and PC. Each keystroke asked for a new preview, the card waited for it
// and vanished in between. This types a full price one key at a time, with previews landing
// mid-typing and one failing, and checks the box is the same one, still focused, every time.
import { act, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const rpc = vi.fn();
vi.mock('../../lib/supabase', () => ({ supabase: { rpc: (...a: unknown[]) => rpc(...a) } }));

import FixClose from './FixClose';
import { TEXT } from './fixCloseText';

/** What close_fix_preview answers: the stored Dow close for Nov 20 (as fmt_money4 writes it). */
function preview(close: string | null) {
  return {
    fund_id: 'dow',
    fund_name: 'Dow Jones',
    date: '2026-11-20',
    day_words: 'Nov 20',
    old_close_words: '$480.8600',
    fetched_words: 'Nov 20 at 9:00 pm',
    final: true,
    new_close_words:
      close === null ? null : `$${close}${'0'.repeat(4 - (close.split('.')[1] ?? '').length)}`,
    adjustments: [],
  };
}

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

describe('Fix a close: typing the official close', () => {
  it('keeps the same box, focused, while a full price is typed digit by digit', async () => {
    let calls = 0;
    rpc.mockImplementation(async (_fn: string, a: { p_close: string | null }) => {
      calls += 1;
      // One preview fails part-way through: the box must stay put even then.
      if (calls === 3) return { data: null, error: { message: 'Something went wrong.' } };
      return { data: preview(a.p_close), error: null };
    });
    render(
      <MemoryRouter initialEntries={['/parent/fix-close?fund=dow&date=2026-11-20']}>
        <FixClose />
      </MemoryRouter>,
    );
    await settle(500);
    expect(screen.getByText(/^Stored close for Nov 20: \$480\.86 \(/)).toBeTruthy();

    const box = screen.getByLabelText(TEXT.official) as HTMLInputElement;
    box.focus();
    const price = '481.08';
    for (let i = 1; i <= price.length; i++) {
      fireEvent.change(box, { target: { value: price.slice(0, i) } });
      // Some keys come quicker than the 400 ms wait, some slower, so previews land mid-typing.
      await settle(i % 2 === 0 ? 450 : 100);
      const now = screen.getByLabelText(TEXT.official);
      expect(now).toBe(box);
      expect(document.activeElement).toBe(box);
      expect(box.value).toBe(price.slice(0, i));
      // The stored close stays on screen too, never "Checking…" between keys.
      expect(screen.getByText(/^Stored close for Nov 20: \$480\.86 \(/)).toBeTruthy();
    }

    fireEvent.change(screen.getByLabelText(TEXT.source), {
      target: { value: 'Yahoo Finance daily history' },
    });
    await settle(500);
    expect(screen.getByText('Dow Jones, Nov 20: $480.86 → $481.08')).toBeTruthy();
    expect(screen.getByRole('button', { name: TEXT.yes })).toHaveProperty('disabled', false);
  });

  it('asks the database about a price only once it has at most 2 decimals', async () => {
    rpc.mockImplementation(async (_fn: string, a: { p_close: string | null }) => ({
      data: preview(a.p_close),
      error: null,
    }));
    render(
      <MemoryRouter initialEntries={['/parent/fix-close?fund=dow&date=2026-11-20']}>
        <FixClose />
      </MemoryRouter>,
    );
    await settle(500);
    const box = screen.getByLabelText(TEXT.official);
    fireEvent.change(box, { target: { value: '481.085' } });
    await settle(500);
    expect(screen.getByText(TEXT.officialBad)).toBeTruthy();
    expect(rpc).toHaveBeenLastCalledWith('close_fix_preview', {
      p_fund_id: 'dow',
      p_date: '2026-11-20',
      p_close: null,
    });
  });
});

// The clipboard option for keys and passwords (Dad, 2026-10-10).
import { describe, expect, it, vi } from 'vitest';
import { cleanCopied, clipboardCommands } from './clipboard.ts';
import { askSecret, secretFrom, type ClipboardIo } from './prompt.ts';

const KEY = 'sb_secret_abcdefghijklmnopqrstuvwxyz';
const fakeClipboard = (copied: string | null, clears = true) => {
  const io: ClipboardIo & { cleared: number } = {
    cleared: 0,
    read: () => copied,
    clear: () => {
      io.cleared++;
      return clears;
    },
  };
  return io;
};
const answers = (...a: string[]) => {
  const asked: string[] = [];
  return { asked, next: async (q: string) => (asked.push(q), a.shift() ?? '') };
};
const isKey = (s: string) => (s.startsWith('sb_secret_') ? null : "That isn't a Supabase key.");

describe('reading and clearing the clipboard', () => {
  it('uses each system’s own tool', () => {
    expect(clipboardCommands('win32')?.read[0]).toBe('powershell.exe');
    expect(clipboardCommands('win32')?.clear).toEqual(['cmd.exe', ['/d', '/c', 'echo off | clip']]);
    expect(clipboardCommands('darwin')?.read).toEqual(['pbpaste', []]);
    expect(clipboardCommands('linux')?.read[0]).toBe('xclip');
    expect(clipboardCommands('aix')).toBeNull();
  });
  it('drops the line breaks, spaces and byte-order mark copying can add', () => {
    expect(cleanCopied(`\uFEFF ${KEY}\r\n`)).toBe(KEY);
  });
});

describe('a hidden answer', () => {
  it('is what was typed, when something was typed', () => {
    expect(secretFrom('typed', fakeClipboard(KEY))).toEqual({
      value: 'typed',
      fromClipboard: false,
    });
  });
  it('is what was copied, when Enter alone was pressed', () => {
    expect(secretFrom('', fakeClipboard(KEY))).toEqual({ value: KEY, fromClipboard: true });
    expect(secretFrom('', fakeClipboard(''))).toEqual({ value: null, fromClipboard: true });
    expect(secretFrom('', fakeClipboard(null))).toEqual({ value: null, fromClipboard: true });
  });
});

describe('asking for a key', () => {
  it('takes it from the clipboard, never shows it, and clears the clipboard', async () => {
    const log = vi.spyOn(console, 'log').mockImplementation(() => {});
    const io = fakeClipboard(KEY);
    const a = answers('');
    await expect(askSecret('Service role key', isKey, io, a.next)).resolves.toEqual({
      value: KEY,
      fromClipboard: true,
    });
    expect(a.asked[0]).toBe('Service role key (or press Enter to use what you copied): ');
    expect(io.cleared).toBe(1);
    expect(log.mock.calls.flat().join('\n')).not.toContain(KEY);
    log.mockRestore();
  });
  it('asks again when what was copied is the wrong thing, without clearing or showing it', async () => {
    const log = vi.spyOn(console, 'log').mockImplementation(() => {});
    const io = fakeClipboard('sb_publishable_oops');
    const a = answers('', KEY);
    await expect(askSecret('Service role key', isKey, io, a.next)).resolves.toEqual({
      value: KEY,
      fromClipboard: false,
    });
    expect(a.asked).toHaveLength(2);
    expect(io.cleared).toBe(0);
    const said = log.mock.calls.flat().join('\n');
    expect(said).toContain("That isn't a Supabase key. (That was what you copied.)");
    expect(said).not.toContain('sb_publishable_oops');
    log.mockRestore();
  });
  it('says so when the clipboard is empty', async () => {
    const log = vi.spyOn(console, 'log').mockImplementation(() => {});
    const a = answers('', KEY);
    await askSecret('Service role key', isKey, fakeClipboard(null), a.next);
    expect(log.mock.calls.flat().join('\n')).toContain('The clipboard is empty');
    log.mockRestore();
  });
  it('says when the clipboard couldn’t be cleared', async () => {
    const log = vi.spyOn(console, 'log').mockImplementation(() => {});
    await askSecret('Service role key', isKey, fakeClipboard(KEY, false), answers('').next);
    expect(log.mock.calls.flat().join('\n')).toContain("Couldn't clear the clipboard");
    log.mockRestore();
  });
});

// Reading a key or password from the clipboard, for the setup scripts (Dad,
// 2026-10-10: pasting into hidden prompts was unreliable in PowerShell). The value
// is never shown or saved, and the clipboard is cleared straight after.

import { execFileSync } from 'node:child_process';

type Command = [file: string, args: string[]];

/** How to read and clear the clipboard on each system. */
export function clipboardCommands(
  platform: NodeJS.Platform,
): { read: Command; clear: Command } | null {
  switch (platform) {
    case 'win32':
      return {
        read: [
          'powershell.exe',
          ['-NoProfile', '-NonInteractive', '-Command', 'Get-Clipboard -Raw'],
        ],
        // "echo off" prints nothing, so clip.exe sets the clipboard to empty.
        clear: ['cmd.exe', ['/d', '/c', 'echo off | clip']],
      };
    case 'darwin':
      return { read: ['pbpaste', []], clear: ['sh', ['-c', 'printf "" | pbcopy']] };
    case 'linux':
      return {
        read: ['xclip', ['-selection', 'clipboard', '-o']],
        clear: ['sh', ['-c', 'printf "" | xclip -selection clipboard']],
      };
    default:
      return null;
  }
}

/** What was copied, without the line breaks, spaces or byte-order mark copying can add. */
export function cleanCopied(raw: string): string {
  return raw.replace(/^\uFEFF/, '').trim();
}

/** The clipboard's text, or null if it can't be read. */
export function readClipboard(platform: NodeJS.Platform = process.platform): string | null {
  const c = clipboardCommands(platform);
  if (!c) return null;
  try {
    const out = execFileSync(c.read[0], c.read[1], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      windowsHide: true,
    });
    return cleanCopied(out);
  } catch {
    return null;
  }
}

/** Empties the clipboard, so the key or password doesn't stay there. True if it worked. */
export function clearClipboard(platform: NodeJS.Platform = process.platform): boolean {
  const c = clipboardCommands(platform);
  if (!c) return false;
  try {
    execFileSync(c.clear[0], c.clear[1], { stdio: 'ignore', windowsHide: true });
    return true;
  } catch {
    return false;
  }
}

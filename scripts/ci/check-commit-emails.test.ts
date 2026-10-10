import { describe, expect, it } from 'vitest';
import { isNoreply } from './check-commit-emails.ts';

describe('commit email check', () => {
  it.each([
    '320070380+JarrettWD@users.noreply.github.com',
    '1+a-b@users.noreply.github.com',
    'noreply@github.com',
  ])('allows %s', (email) => {
    expect(isNoreply(email)).toBe(true);
  });

  it.each([
    'someone@gmail.com',
    'JarrettWD@users.noreply.github.com.evil.com',
    'noreply@anthropic.com',
    'x@users.noreply.github.co',
    '',
  ])('refuses %s', (email) => {
    expect(isNoreply(email)).toBe(false);
  });
});

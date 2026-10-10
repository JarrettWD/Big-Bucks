import { describe, expect, it } from 'vitest';
import { identEmail, isNoreply, pushRanges } from './check-commit-emails.ts';

describe('commit email check', () => {
  it.each([
    '12345678+example-user@users.noreply.github.com',
    '1+a-b@users.noreply.github.com',
    'noreply@github.com',
  ])('allows %s', (email) => {
    expect(isNoreply(email)).toBe(true);
  });

  it.each([
    'someone@example.com',
    'example-user@users.noreply.github.com.evil.example',
    'noreply@anthropic.com',
    'x@users.noreply.github.co',
    '',
  ])('refuses %s', (email) => {
    expect(isNoreply(email)).toBe(false);
  });

  it("reads the email from git's identity line", () => {
    expect(
      identEmail('Example User <12345678+example-user@users.noreply.github.com> 1760000000 -0600'),
    ).toBe('12345678+example-user@users.noreply.github.com');
    expect(identEmail('no email here')).toBe('');
  });

  it('works out what a push would publish', () => {
    const z = '0'.repeat(40);
    const a = 'a'.repeat(40);
    const b = 'b'.repeat(40);
    expect(pushRanges(`refs/heads/main ${a} refs/heads/main ${b}\n`)).toEqual([[`${b}..${a}`]]);
    expect(pushRanges(`refs/heads/new ${a} refs/heads/new ${z}\n`)).toEqual([
      [a, '--not', '--remotes'],
    ]);
    expect(pushRanges(`(delete) ${z} refs/heads/old ${b}\n`)).toEqual([]);
    expect(pushRanges('')).toEqual([]);
  });
});

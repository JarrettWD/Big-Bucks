// The guards that keep the time machine, the demo and jobs:local off production.
import { describe, expect, it } from 'vitest';
import { addressProblem, databaseProblem, LOCAL_DB_URL } from './db.ts';

describe('database address guard', () => {
  it('allows the local database', () => {
    expect(addressProblem(LOCAL_DB_URL)).toBeNull();
  });
  it.each([
    'postgresql://postgres:x@db.abcdefghijklmnop.supabase.co:5432/postgres',
    'postgresql://postgres:postgres@127.0.0.1:5432/postgres',
    'postgresql://postgres:postgres@10.0.0.5:54322/postgres',
    'not a url',
  ])('refuses %s', (url) => {
    expect(addressProblem(url)).toMatch(/^Refusing to run/);
  });
});

describe('database guard (pre-launch audit)', () => {
  it('allows a local copy', () => {
    expect(databaseProblem('true', false)).toBeNull();
  });
  it('refuses a database that does not say is_local_dev = true', () => {
    expect(databaseProblem('false', false)).toMatch(/is_local_dev = true/);
    expect(databaseProblem(undefined, false)).toMatch(/is_local_dev = true/);
  });
  it('refuses a database marked as production, whatever is_local_dev says', () => {
    expect(databaseProblem('true', true)).toBe(
      'Refusing to run: this database is marked as production.',
    );
  });
});

// @vitest-environment node
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { albertaDate, backupMessage, clientConfig, isLocalHost, readCa } from './backup.ts';

describe('the backup label: the Alberta date (UTC−6 all year)', () => {
  it('labels an 8:45 pm Alberta backup by its own day, not the next UTC day', () => {
    // 8:45 pm on Nov 24 in Alberta is 02:45 UTC on Nov 25.
    expect(albertaDate('2026-11-25T02:45:00.000000Z')).toBe('2026-11-24');
  });

  it('labels the 7:00 am morning backup by the same day', () => {
    expect(albertaDate('2026-11-24T13:00:00.000000Z')).toBe('2026-11-24');
  });

  it('puts 11:59 pm and 12:00 am on either side of midnight', () => {
    expect(albertaDate('2026-11-25T05:59:59.999999Z')).toBe('2026-11-24');
    expect(albertaDate('2026-11-25T06:00:00.000000Z')).toBe('2026-11-25');
  });

  it('crosses a month and a year correctly', () => {
    expect(albertaDate('2027-01-01T03:00:00.000000Z')).toBe('2026-12-31');
    expect(albertaDate('2026-12-01T05:00:00Z')).toBe('2026-11-30');
  });

  it('refuses a time that is not UTC rather than guess', () => {
    expect(() => albertaDate('2026-11-25 02:45:00')).toThrow("Can't read the backup time");
    expect(() => albertaDate('2026-11-25T02:45:00-06:00')).toThrow("Can't read the backup time");
  });

  it('changes only the date in the commit message', () => {
    expect(backupMessage('2026-11-25T02:45:00.000000Z', 34, 5210, 812, false)).toBe(
      'Backup 2026-11-24: 34 tables, 5210 rows, 812 ledger rows',
    );
    expect(backupMessage('2026-12-06T13:00:04.123456Z', 34, 120, 0, true)).toBe(
      'Backup 2026-12-06: 34 tables, 120 rows, 0 ledger rows (after the pre-launch reset)',
    );
  });
});

const PROD =
  'postgresql://backup_reader.abcdefghijklmnopqrst:pw@aws-1-ca-central-1.pooler.supabase.com:5432/postgres?sslmode=require';
const dir = mkdtempSync(join(tmpdir(), 'bb-ca-'));
const ca = join(dir, 'supabase-ca.crt');
writeFileSync(ca, '-----BEGIN CERTIFICATE-----\nMIIfake\n-----END CERTIFICATE-----\n');

describe('the backup connection', () => {
  it("checks Supabase's certificate and name (verify-full)", () => {
    const prod = clientConfig(PROD, ca);
    expect(prod.ssl).toEqual({ ca: readCa(ca), rejectUnauthorized: true });
    // The sslmode in the string is dropped, so it can't weaken the check above.
    expect(prod.connectionString).not.toContain('sslmode');
    expect(prod.connectionString).toContain('backup_reader.abcdefghijklmnopqrst');
  });

  it('refuses to connect to Supabase without the CA certificate', () => {
    expect(() => clientConfig(PROD, join(dir, 'missing.crt'))).toThrow(
      "Supabase's CA certificate is missing",
    );
    const notCert = join(dir, 'note.crt');
    writeFileSync(notCert, 'hello');
    expect(() => clientConfig(PROD, notCert)).toThrow("isn't a certificate");
  });

  it('uses no TLS for the local copy on this computer', () => {
    const local = clientConfig(
      'postgresql://backup_reader:pw@127.0.0.1:44322/postgres',
      join(dir, 'missing.crt'),
    );
    expect(local.ssl).toBeUndefined();
  });

  it('knows which addresses are this computer', () => {
    expect(isLocalHost('127.0.0.1')).toBe(true);
    expect(isLocalHost('localhost')).toBe(true);
    expect(isLocalHost('aws-1-ca-central-1.pooler.supabase.com')).toBe(false);
  });
});

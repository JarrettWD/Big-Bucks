// @vitest-environment node
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { clientConfig, isLocalHost, readCa } from './backup.ts';

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
      'postgresql://backup_reader:pw@127.0.0.1:54322/postgres',
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

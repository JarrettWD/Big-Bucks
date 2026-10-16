import { describe, expect, it } from 'vitest';
import { encodeUnder, fitSize, PHOTO, THUMB, toBase64 } from './photo';

describe('wish photos are made small on her phone (stage 9)', () => {
  it('fits the long side, keeps the shape, never enlarges', () => {
    expect(fitSize(4000, 3000, PHOTO.side)).toEqual({ width: 800, height: 600 });
    expect(fitSize(3000, 4000, PHOTO.side)).toEqual({ width: 600, height: 800 });
    expect(fitSize(4000, 3000, THUMB.side)).toEqual({ width: 160, height: 120 });
    expect(fitSize(500, 300, PHOTO.side)).toEqual({ width: 500, height: 300 });
    expect(fitSize(8000, 10, THUMB.side)).toEqual({ width: 160, height: 1 });
  });

  it('keeps the limits the database checks', () => {
    expect(PHOTO.bytes).toBe(153600);
    expect(THUMB.bytes).toBe(20480);
  });

  it('lowers the quality, then the size, until it fits', async () => {
    const tried: string[] = [];
    // A pretend encoder: bytes = 200 KB × scale² × quality.
    const blob = await encodeUnder(async (scale, quality) => {
      tried.push(`${scale}@${quality}`);
      return new Blob([new Uint8Array(Math.round(200_000 * scale * scale * quality))]);
    }, PHOTO.bytes);
    expect(blob!.size).toBeLessThanOrEqual(PHOTO.bytes);
    expect(tried[0]).toBe('1@0.85');
    expect(tried.at(-1)).toBe('1@0.75');
  });

  it('gives up (null) rather than send something too big', async () => {
    const blob = await encodeUnder(
      async () => new Blob([new Uint8Array(PHOTO.bytes + 1)]),
      PHOTO.bytes,
    );
    expect(blob).toBeNull();
  });

  it('sends the bytes as base64, exactly', async () => {
    const bytes = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 1, 2, 250]);
    expect(await toBase64(new Blob([bytes]))).toBe(btoa(String.fromCharCode(...bytes)));
  });
});

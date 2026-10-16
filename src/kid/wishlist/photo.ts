// Her wish's photo, made small on her phone before it's sent: at most 800 px on its
// long side and 150 KB, plus a 160 px thumbnail of at most 20 KB for the list. Drawing
// it again as a new JPEG also leaves behind everything hidden in the original file,
// including where it was taken. The database checks the same limits again.

export const PHOTO = { side: 800, bytes: 150 * 1024 };
export const THUMB = { side: 160, bytes: 20 * 1024 };

/** The size to draw at: the long side at most `max`, never made bigger. */
export function fitSize(
  width: number,
  height: number,
  max: number,
): { width: number; height: number } {
  const scale = Math.min(1, max / Math.max(width, height));
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale)),
  };
}

/** Encodes at falling quality, then smaller sizes, until it fits. Null if it never does. */
export async function encodeUnder(
  encode: (scale: number, quality: number) => Promise<Blob | null>,
  limit: number,
): Promise<Blob | null> {
  for (const scale of [1, 0.8, 0.6, 0.45]) {
    for (const quality of [0.85, 0.75, 0.65, 0.5]) {
      const blob = await encode(scale, quality);
      if (blob && blob.size <= limit) return blob;
    }
  }
  return null;
}

/** A Blob's bytes as base64 (what the database function takes). */
export async function toBase64(blob: Blob): Promise<string> {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000)
    s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

export class PhotoProblem extends Error {}

async function shrink(
  image: ImageBitmap,
  box: { side: number; bytes: number },
): Promise<Blob | null> {
  const base = fitSize(image.width, image.height, box.side);
  return encodeUnder((scale, quality) => {
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(base.width * scale));
    canvas.height = Math.max(1, Math.round(base.height * scale));
    const ctx = canvas.getContext('2d');
    if (!ctx) return Promise.resolve(null);
    // A white background, so a see-through picture doesn't turn black as a JPEG.
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(image, 0, 0, canvas.width, canvas.height);
    return new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', quality));
  }, box.bytes);
}

/** The photo and its thumbnail, as base64 JPEGs. Throws PhotoProblem with kid words. */
export async function preparePhoto(file: File): Promise<{ photo: string; thumb: string }> {
  let image: ImageBitmap;
  try {
    // Turned the right way up, as the camera meant it.
    image = await createImageBitmap(file, { imageOrientation: 'from-image' });
  } catch {
    throw new PhotoProblem("That photo didn't work. Try another one or a screenshot.");
  }
  try {
    const [photo, thumb] = await Promise.all([shrink(image, PHOTO), shrink(image, THUMB)]);
    if (!photo || !thumb) throw new PhotoProblem('That photo is too big. Try another one.');
    return { photo: await toBase64(photo), thumb: await toBase64(thumb) };
  } finally {
    image.close();
  }
}

// The app-wide safety net's words (ErrorBoundary.tsx). The kids' screens and Dad's screens
// (everything under /parent, "View as" included) each get their own last line (Dad, 2026-10-19).

export const BOUNDARY_TEXT = {
  title: 'Something went wrong on this screen',
  kidBody:
    "Big Bucks couldn't show this page. Go back and try again. If it keeps happening, tell Mom or Dad what you were doing.",
  parentBody:
    "Big Bucks couldn't show this page. Go back and try again. If it keeps happening, note what you were doing and tell Buck.",
  back: 'Go back',
  home: 'Go to the start',
} as const;

/** Dad's screens are the ones under /parent. */
export function isParentPath(pathname: string): boolean {
  return pathname === '/parent' || pathname.startsWith('/parent/');
}

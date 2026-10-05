// The preview behind every Settings change: the real action, run by the database
// and rolled back (parent_change_preview).

import { useEffect, useRef, useState } from 'react';
import { supabase } from '../../lib/supabase';
import type { ChangePreview } from './settingsText';

export type PreviewAction =
  'set_setting' | 'add_rate' | 'edit_note' | 'edit_glossary' | 'cancel_change';

/**
 * Asks the database what the change would do, after Dad pauses typing. `args`
 * null means what's typed isn't valid yet. The result is kept only for the exact
 * args it was asked about.
 */
export function usePreview(action: PreviewAction, args: Record<string, unknown> | null) {
  const key = args ? JSON.stringify(args) : null;
  const [preview, setPreview] = useState<{ key: string; result: ChangePreview } | null>(null);
  const seq = useRef(0);

  useEffect(() => {
    const mine = ++seq.current;
    if (key === null) return;
    const t = window.setTimeout(async () => {
      const { data, error } = await supabase.rpc('parent_change_preview', {
        p_action: action,
        p_args: JSON.parse(key),
      });
      if (mine !== seq.current) return;
      setPreview({
        key,
        result: error
          ? { problem: error.message, summary: null, notices: [], facts: null }
          : (data as ChangePreview),
      });
    }, 400);
    return () => window.clearTimeout(t);
  }, [action, key]);

  return preview && preview.key === key ? preview.result : null;
}

/** Runs the real action; returns the database's message if it refused. */
export async function runAction(
  fn: string,
  params: Record<string, unknown>,
): Promise<string | null> {
  const { error } = await supabase.rpc(fn, params);
  return error ? error.message : null;
}

/** Puts focus on the change's heading when it opens, for keyboards and screen readers. */
export function useFocusOnOpen<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  useEffect(() => {
    ref.current?.focus();
  }, []);
  return ref;
}

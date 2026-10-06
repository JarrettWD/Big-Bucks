// Each girl's onboarding and agreement (parent_agreements), for Approvals and the dashboard.

import { useCallback, useEffect, useState } from 'react';
import { supabase } from '../../lib/supabase';

export interface KidAgreement {
  account_id: string;
  kid: string;
  is_test: boolean;
  onboarding_done: boolean;
  current_version: number;
  signed_version: number | null;
  signed_at: string | null;
  dad_signed_at: string | null;
}

export const waitingForDad = (k: KidAgreement) => k.signed_version !== null && !k.dad_signed_at;

export function useAgreements() {
  const [list, setList] = useState<KidAgreement[] | null>(null);
  const reload = useCallback(async () => {
    const { data } = await supabase.rpc('parent_agreements');
    setList((data ?? []) as KidAgreement[]);
  }, []);
  useEffect(() => {
    let live = true;
    void supabase.rpc('parent_agreements').then(({ data }) => {
      if (live) setList((data ?? []) as KidAgreement[]);
    });
    return () => {
      live = false;
    };
  }, []);
  return { list, reload };
}

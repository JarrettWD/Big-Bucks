// Her questions to Dad ("Something looks wrong?"), newest first, with Dad's
// answers. Dates come from the database (my_questions); she sees only her own.

import { useCallback, useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';

export interface Question {
  id: number;
  transaction_id: number | null;
  message: string;
  reply: string | null;
  answered: boolean;
  asked_on: string;
  answered_on: string | null;
}

export function useQuestions(accountId: string | null) {
  const [questions, setQuestions] = useState<Question[]>([]);
  const [tick, setTick] = useState(0);
  const reload = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    if (!accountId) return;
    let alive = true;
    supabase.rpc('my_questions', { p_account_id: accountId }).then(({ data }) => {
      if (alive) setQuestions((data ?? []) as Question[]);
    });
    return () => {
      alive = false;
    };
  }, [accountId, tick]);

  return { questions, reload };
}

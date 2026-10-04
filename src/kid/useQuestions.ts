// Her questions to Dad ("Something looks wrong?"), newest first, with Dad's
// answers. Dates come from the database (my_questions); she sees only her own.

import { useCallback, useEffect, useState } from 'react';
import { kidRpc, type KidView } from './kidView';

export interface Question {
  id: number;
  transaction_id: number | null;
  message: string;
  reply: string | null;
  answered: boolean;
  asked_on: string;
  answered_on: string | null;
}

export function useQuestions(view: KidView | null) {
  const [questions, setQuestions] = useState<Question[]>([]);
  const [tick, setTick] = useState(0);
  const reload = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    if (!view) return;
    let alive = true;
    kidRpc(view, 'my_questions', { p_account_id: view.accountId }).then(({ data }) => {
      if (alive) setQuestions((data ?? []) as Question[]);
    });
    return () => {
      alive = false;
    };
  }, [view, tick]);

  return { questions, reload };
}

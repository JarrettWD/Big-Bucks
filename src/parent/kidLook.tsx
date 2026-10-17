// Dad's screens (stage 10): each kid's avatar and badges, read through parent_looks
// and kid_badges (parent with the second step). Nothing here changes anything.

import { useEffect, useState } from 'react';
import { Avatar, type Look } from '../components/Avatar';
import { formatDate } from '../lib/format';
import { supabase } from '../lib/supabase';
import type { Badges } from '../kid/look/lookText';

/** Every kid's look, by account id. */
// eslint-disable-next-line react-refresh/only-export-components
export function useParentLooks(): Record<string, Look> {
  const [looks, setLooks] = useState<Record<string, Look>>({});
  useEffect(() => {
    let live = true;
    void supabase.rpc('parent_looks').then(({ data }) => {
      if (live && data) setLooks(data as Record<string, Look>);
    });
    return () => {
      live = false;
    };
  }, []);
  return looks;
}

/** Her avatar, when "Make it yours" is on for her; nothing otherwise. */
export function KidAvatar({ look, size = 40 }: { look: Look | undefined; size?: number }) {
  if (!look?.on) return null;
  return (
    <Avatar
      theme={look.theme}
      animal={look.animal}
      accessory={look.accessory}
      size={size}
      label=""
    />
  );
}

/** Her badges, one icon each with its name and date; "No badges yet." with none. */
export function KidBadges({ accountId, look }: { accountId: string; look: Look | undefined }) {
  const [data, setData] = useState<Badges | null>(null);
  useEffect(() => {
    if (!look?.badges_on) return;
    let live = true;
    void supabase.rpc('kid_badges', { p_account_id: accountId }).then(({ data: d }) => {
      if (live && d) setData(d as Badges);
    });
    return () => {
      live = false;
    };
  }, [accountId, look?.badges_on]);
  if (!look?.badges_on || !data) return null;
  const kinds = new Map(data.kinds.map((k) => [k.key, k]));
  if (data.earned.length === 0) return <p className="dash__muted">No badges yet.</p>;
  return (
    <p className="dash__badges">
      <span>🏅 {data.earned.length === 1 ? '1 badge' : `${data.earned.length} badges`}:</span>{' '}
      {data.earned.map((b) => {
        const k = kinds.get(b.badge);
        return (
          <span
            key={b.badge}
            className="dash__badge"
            title={`${k?.name} · ${formatDate(b.earned_on)}`}
          >
            <span aria-hidden="true">{k?.emoji}</span>
            <span className="dash__badge-name">
              {k?.name} ({formatDate(b.earned_on)})
            </span>
          </span>
        );
      })}
    </p>
  );
}

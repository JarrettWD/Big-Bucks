// Her history lines, used on Home (the last 5) and on the "See all" page.

import { formatDate } from '../../lib/format';
import { describeActivity, type ActivityRow } from './activityText';

export function ActivityList({ rows, thisYear }: { rows: ActivityRow[]; thisYear: number }) {
  if (rows.length === 0)
    return <p className="muted">Nothing here yet. Your story starts with your first deposit!</p>;
  return (
    <ul className="activity">
      {rows.map((r) => {
        const line = describeActivity(r);
        return (
          <li key={line.key} className={`activity__row activity__row--${line.tone}`}>
            <span className="activity__icon" aria-hidden="true">
              {line.icon}
            </span>
            <span className="activity__text">
              <span className="activity__title">{line.title}</span>
              {line.detail && <span className="activity__detail">{line.detail}</span>}
              <span className="activity__date">{formatDate(line.day, thisYear)}</span>
            </span>
            {line.amount && <span className="activity__amount">{line.amount}</span>}
          </li>
        );
      })}
    </ul>
  );
}

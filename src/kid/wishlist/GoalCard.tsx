// Her savings goal on Home (Stage 9): the wish she chose after "Still want this?",
// a progress bar from her total worth, and roughly when, worded as a guess. Shown
// in Dad's "View as" too (read through parent_view), never with the "Got it" marker.

import { Link } from 'react-router-dom';
import { formatCents } from '../../lib/money';
import { useKidView } from '../kidView';
import { Progress } from './Progress';
import { WishPhoto } from './WishPhoto';
import { DIP_LINE, progressLine, projectionLine, showDip, TEXT, type Goal } from './wishText';
import './WishList.css';

export function GoalCard({ goal }: { goal: Goal }) {
  const view = useKidView();
  const projection = projectionLine(goal, goal.worth_cents);
  return (
    <section className="card wish-card wish-card--goal home__goal" aria-labelledby="h-goal">
      <div className="wish-card__top">
        {goal.has_photo && !view.viewing && (
          <WishPhoto id={goal.id} version={goal.photo_at} name={goal.name} />
        )}
        <div className="wish-card__what">
          <p className="wish__tag">🎯 {TEXT.goalCardTitle}</p>
          <h2 id="h-goal" className="wish-card__name">
            {goal.name}
          </h2>
          <p className="wish-card__meta">
            <span className="wish-card__price">{formatCents(goal.price_cents)}</span>
          </p>
        </div>
      </div>
      <Progress percent={goal.percent} label={progressLine(goal)} />
      <p className="wish-card__line">{progressLine(goal)}</p>
      {projection && <p className="muted">{projection}</p>}
      {showDip(goal.funds_dipped, goal) && <p className="wish__dip">{DIP_LINE}</p>}
      {!view.viewing && (
        <Link className="btn btn--soft" to={`${view.base}/wishlist`}>
          {TEXT.seeWishList}
        </Link>
      )}
    </section>
  );
}

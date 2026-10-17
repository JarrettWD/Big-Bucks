// Home's card for her avatar (stage 10): tap it to change her colour and animal, and
// "Your badges" beside it. Absent while both switches are off for her.

import { Link } from 'react-router-dom';
import { Avatar } from '../../components/Avatar';
import { useKid } from '../KidShell';
import { TEXT } from './lookText';
import './Look.css';

export function MeCard() {
  const { view, summary } = useKid();
  const look = summary.look;
  if (!look || (!look.on && !look.badges_on)) return null;
  return (
    <section className="card home__me me" aria-label={view.viewing ? `${view.name}'s look` : 'You'}>
      {look.on && (
        <Link className="me__avatar" to={`${view.base}/look`} aria-label={TEXT.openLook}>
          <Avatar
            theme={look.theme}
            animal={look.animal}
            accessory={look.accessory}
            size={72}
            label=""
          />
        </Link>
      )}
      <div className="me__words">
        <div className="me__links">
          {look.on && (
            <Link className="btn btn--soft btn--small" to={`${view.base}/look`}>
              🎨 {TEXT.lookTitle}
            </Link>
          )}
          {look.badges_on && (
            <Link className="btn btn--soft btn--small" to={`${view.base}/badges`}>
              {TEXT.badgesLink}
            </Link>
          )}
        </div>
      </div>
    </section>
  );
}

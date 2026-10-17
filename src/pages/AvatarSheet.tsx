// Every animal wearing every accessory, in every theme colour: Dad's check that each
// hat sits right (stage 10). Pictures only, no account data, so it needs no sign-in.

import { Avatar } from '../components/Avatar';
import { ACCESSORIES, ANIMALS, THEMES } from '../lib/look';

export default function AvatarSheet() {
  const params = new URLSearchParams(window.location.search);
  const size = Number(params.get('size')) || 72;
  // ?animals=moose,hedgehog shows just those (a closer look).
  const only = params.get('animals')?.split(',');
  const shown = only ? ANIMALS.filter((a) => only.includes(a.key)) : ANIMALS;
  return (
    <main style={{ padding: '1rem', fontFamily: 'var(--bb-font-body)', background: '#fff' }}>
      <h1 style={{ fontFamily: 'var(--bb-font-heading)', color: 'var(--bb-ink)' }}>
        Avatars and accessories
      </h1>
      <table style={{ borderCollapse: 'collapse' }}>
        <thead>
          <tr>
            <th />
            <th style={{ padding: 4, fontSize: 12 }}>None</th>
            {ACCESSORIES.map((a) => (
              <th key={a.key} style={{ padding: 4, fontSize: 12 }}>
                {a.name}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {shown.map((an, i) => (
            <tr key={an.key}>
              <th style={{ textAlign: 'left', padding: 4, fontSize: 12 }}>{an.name}</th>
              {[null, ...ACCESSORIES.map((a) => a.key)].map((acc) => (
                <td key={acc ?? 'none'} style={{ padding: 6 }}>
                  <Avatar
                    theme={THEMES[i % THEMES.length].hex}
                    animal={an.key}
                    accessory={acc}
                    size={size}
                  />
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </main>
  );
}

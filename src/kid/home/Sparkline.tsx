// A fund's last 30 closes as a small line. Decoration only: the words next to it
// ("Up 0.47%") carry the meaning, so screen readers skip it.

interface Props {
  points: { d: string; c: number }[];
  colour: string;
}

export function Sparkline({ points, colour }: Props) {
  if (points.length < 2) return null;
  const values = points.map((p) => Number(p.c));
  const min = Math.min(...values);
  const max = Math.max(...values);
  const span = max - min || 1;
  const path = values
    .map((v, i) => {
      const x = (i / (values.length - 1)) * 100;
      const y = 30 - ((v - min) / span) * 26 - 2;
      return `${i === 0 ? 'M' : 'L'}${x.toFixed(2)},${y.toFixed(2)}`;
    })
    .join(' ');
  return (
    <svg
      className="spark"
      viewBox="0 0 100 32"
      preserveAspectRatio="none"
      aria-hidden="true"
      focusable="false"
    >
      <path
        d={path}
        fill="none"
        stroke="var(--bb-outline)"
        strokeWidth="4.5"
        strokeLinejoin="round"
        vectorEffect="non-scaling-stroke"
        opacity="0.25"
      />
      <path
        d={path}
        fill="none"
        stroke={colour}
        strokeWidth="2.5"
        strokeLinejoin="round"
        vectorEffect="non-scaling-stroke"
      />
    </svg>
  );
}

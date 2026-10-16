// The progress bar toward a wish or her goal. The percent comes from the database
// (rounded down, so it's full only when she really has enough).

export function Progress({ percent, label }: { percent: number; label: string }) {
  return (
    <div
      className="wish__bar"
      role="progressbar"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={percent}
      aria-label={label}
    >
      <span style={{ width: `${percent}%` }} />
    </div>
  );
}

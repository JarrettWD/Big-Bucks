// The kid screen still to come: the Wish List (stage 9) is a placeholder. Home
// is in ./home, Graphs in ./graphs, Buy / Sell in ./trade and the notices list
// in ./notices.

function Placeholder({ title }: { title: string }) {
  return (
    <section className="kid-card">
      <h1 className="kid-title">{title}</h1>
      <p className="kid-soon">Coming soon.</p>
    </section>
  );
}

export const KidWishList = () => <Placeholder title="Wish List" />;

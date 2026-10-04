// The kid screens still to come: Graphs (stage 7 part 2c) and the Wish List
// (stage 9) are placeholders. Home is in ./home, Buy / Sell in ./trade and the
// notices list in ./notices.

function Placeholder({ title }: { title: string }) {
  return (
    <section className="kid-card">
      <h1 className="kid-title">{title}</h1>
      <p className="kid-soon">Coming soon.</p>
    </section>
  );
}

export const KidGraphs = () => <Placeholder title="Graphs" />;
export const KidWishList = () => <Placeholder title="Wish List" />;

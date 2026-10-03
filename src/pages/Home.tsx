import './Home.css';

export default function Home() {
  return (
    <main className="home">
      <img
        className="home__icon"
        src={`${import.meta.env.BASE_URL}icons/big-bucks-icon.svg`}
        alt=""
        width={160}
        height={160}
      />
      <h1 className="home__name">Big Bucks</h1>
      <p className="home__tagline">Watch your bucks grow.</p>
    </main>
  );
}

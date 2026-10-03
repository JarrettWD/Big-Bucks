// "You're offline": shown instead of the app whenever there's no connection,
// so she never sees old numbers that might be out of date.

import { useSyncExternalStore } from 'react';
import './Offline.css';

function subscribe(cb: () => void) {
  window.addEventListener('online', cb);
  window.addEventListener('offline', cb);
  return () => {
    window.removeEventListener('online', cb);
    window.removeEventListener('offline', cb);
  };
}

// eslint-disable-next-line react-refresh/only-export-components
export function useOnline(): boolean {
  return useSyncExternalStore(
    subscribe,
    () => navigator.onLine,
    () => true,
  );
}

export function OfflineScreen() {
  return (
    <main className="offline">
      <img
        src={`${import.meta.env.BASE_URL}icons/big-bucks-icon.svg`}
        alt=""
        width={96}
        height={96}
      />
      <h1>You're offline</h1>
      <p>
        Big Bucks needs the internet to show your money. It'll come back as soon as you're
        connected.
      </p>
    </main>
  );
}

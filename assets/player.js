/* ============================================================
   The dock player

   YouTube starts from the iframe URL. Spotify won't — an
   ordinary embed loads paused and needs a second press inside
   their player. Their Embed API can start it for us, so that's
   what this uses.

     import { mountDock, playSong, stopSong } from './assets/player.js';
   ============================================================ */

let dock, frame, host, spotifyApi = null, spotifyCtrl = null, current = null;
let onStop = () => {};

/* ---------- the Spotify embed API, loaded the first time we
     actually need it rather than on every page ---------- */
function loadSpotifyApi() {
  if (spotifyApi) return spotifyApi;
  spotifyApi = new Promise(resolve => {
    if (window.__spotifyIFrameApi) return resolve(window.__spotifyIFrameApi);
    window.onSpotifyIframeApiReady = api => {
      window.__spotifyIFrameApi = api;
      resolve(api);
    };
    const s = document.createElement('script');
    s.src = 'https://open.spotify.com/embed/iframe-api/v1';
    s.async = true;
    document.head.appendChild(s);
  });
  return spotifyApi;
}

export function mountDock(el, opts = {}) {
  dock  = el;
  frame = el.querySelector('iframe');
  host  = el.querySelector('.spothost');
  onStop = opts.onStop || (() => {});

  const close = el.querySelector('#closedock');
  if (close) close.addEventListener('click', stopSong);
}

export function stopSong() {
  if (spotifyCtrl) { try { spotifyCtrl.pause(); } catch {} }
  if (frame) frame.src = '';
  if (host) host.hidden = true;
  if (frame) frame.hidden = false;
  dock?.classList.remove('up');
  current = null;
  onStop();
}

/* Returns the id it started, or null if it stopped. */
export async function playSong(song, id) {
  if (!song || !song.id) return null;

  if (current === id) { stopSong(); return null; }
  current = id;

  if (song.provider === 'spotify') {
    frame.hidden = true;
    host.hidden = false;
    dock.classList.add('up');

    const api = await loadSpotifyApi();

    if (spotifyCtrl) {
      /* one controller, reused — creating a new one each time
         leaves dead iframes behind */
      spotifyCtrl.loadUri('spotify:track:' + song.id);
      spotifyCtrl.play();
    } else {
      api.createController(host, {
        uri: 'spotify:track:' + song.id,
        width: '100%',
        height: 80
      }, ctrl => {
        spotifyCtrl = ctrl;
        ctrl.addListener('ready', () => ctrl.play());
      });
    }
    return id;
  }

  /* YouTube goes straight in */
  host.hidden = true;
  frame.hidden = false;
  frame.style.height = '80px';
  frame.src = `https://www.youtube.com/embed/${song.id}?autoplay=1`;
  dock.classList.add('up');
  return id;
}

/* The markup the dock needs, so pages don't each invent it. */
export const dockHTML = `
<div id="player" class="dock">
  <div class="dockinner">
    <button id="closedock" aria-label="Stop">✕</button>
    <div class="spothost" hidden></div>
    <iframe id="frame" allow="autoplay; encrypted-media" title="Player"></iframe>
  </div>
</div>`;

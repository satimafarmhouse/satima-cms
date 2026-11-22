// Satima CMS installed-app helpers (loaded synchronously in <head> so the splash decision happens before first paint).
// 1. Launch splash: when opened from the home-screen icon, keep a branded loading screen up for about 3 s
//    from launch (tap to skip). Shown once per app launch, never in a normal browser tab.
// 2. Service worker registration (installable app + offline notice; it caches no data).
(() => {
  const SPLASH_MS = 3000, KEY = 'satima-splash-shown', root = document.documentElement;
  const standalone = matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
  let seen = false;
  try { seen = sessionStorage.getItem(KEY) === '1'; } catch { seen = true; }
  if (!standalone || seen) {
    root.classList.add('splash-off');
  } else {
    try { sessionStorage.setItem(KEY, '1'); } catch {}
    const wait = Math.max(0, SPLASH_MS - performance.now());
    root.classList.add('splash-on');
    root.style.setProperty('--splash-ms', `${Math.round(wait)}ms`);
    const hide = () => {
      if (!root.classList.contains('splash-on')) return;
      document.querySelector('.app-splash')?.classList.add('app-splash-leaving');
      setTimeout(() => root.classList.replace('splash-on', 'splash-off'), 350);
    };
    setTimeout(hide, wait);
    document.addEventListener('pointerdown', event => { if (event.target.closest?.('.app-splash')) hide(); }, {capture: true});
  }
  if ('serviceWorker' in navigator && window.isSecureContext) {
    addEventListener('load', () => { navigator.serviceWorker.register('/sw.js', {scope: '/'}).catch(() => {}); });
  }
})();

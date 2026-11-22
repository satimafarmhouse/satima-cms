// Satima CMS service worker: makes the app installable and shows a friendly page when the phone is
// offline. It deliberately stores NO pages, API responses, photos or farmer data on the device.
const OFFLINE_PAGE = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Satima CMS · Offline</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f6f7f3;color:#20342c;font:16px/1.5 system-ui,sans-serif;text-align:center;padding:24px}
h1{font-family:Georgia,serif;font-weight:400;color:#234b3e;margin:0 0 8px}a{display:inline-block;margin-top:16px;padding:12px 20px;border-radius:10px;background:#234b3e;color:#fff;text-decoration:none}</style></head>
<body><main><h1>You're offline</h1><p>Satima CMS needs a connection to the Satima network.<br>Check your signal and that Tailscale is connected, then try again.</p><a href="">Try again</a></main></body></html>`;

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('fetch', event => {
  // Only page loads get the offline fallback; everything else goes straight to the network untouched.
  if (event.request.mode !== 'navigate') return;
  event.respondWith(fetch(event.request).catch(() =>
    new Response(OFFLINE_PAGE, {status: 503, headers: {'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store'}})));
});

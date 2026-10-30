// TutorDeck service worker — installability + offline fallback for static files only.
// Network first; on failure serve a cached copy of same-origin static assets (html/css/js/images).
// Never caches Supabase or any cross-origin request, so no data can go stale.
var CACHE = "td-static-v1";
self.addEventListener("install", function (e) { self.skipWaiting(); });
self.addEventListener("activate", function (e) {
  e.waitUntil(caches.keys().then(function (keys) { return Promise.all(keys.filter(function (k) { return k !== CACHE; }).map(function (k) { return caches.delete(k); })); }).then(function () { return self.clients.claim(); }));
});
self.addEventListener("fetch", function (e) {
  var req = e.request;
  if (req.method !== "GET") return;
  var url = new URL(req.url);
  if (url.origin !== self.location.origin) return;                       // Supabase, Google, fonts: untouched
  if (url.pathname.indexOf("/api/") === 0) return;                        // server functions: untouched
  e.respondWith(fetch(req).then(function (res) {
    if (res && res.ok && (req.destination === "document" || req.destination === "script" || req.destination === "style" || req.destination === "image" || req.destination === "font")) {
      var copy = res.clone(); caches.open(CACHE).then(function (c) { c.put(req, copy); });
    }
    return res;
  }).catch(function () { return caches.match(req); }));
});

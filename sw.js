const V='rap-v26';
const CORE=['./','./index.html','./manifest.webmanifest','./icon.webp','./apple-touch-icon.png','./icon-192.png','./icon-512.png'];
self.addEventListener('install',e=>{
  e.waitUntil(caches.open(V).then(c=>c.addAll(CORE)).then(()=>self.skipWaiting()));
});
self.addEventListener('activate',e=>{
  e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==V).map(x=>caches.delete(x))))
    .then(()=>self.clients.claim()));
});
self.addEventListener('fetch',e=>{
  const u=new URL(e.request.url);
  if(u.pathname.includes('/rest/v1/')) return;          // ห้ามแคช Supabase
  e.respondWith(
    caches.match(e.request).then(hit=>{                  // cache-first = เปิดติดทันที
      const net=fetch(e.request).then(r=>{
        if(r.ok&&e.request.method==='GET')
          caches.open(V).then(c=>c.put(e.request,r.clone()));
        return r;
      }).catch(()=>hit);
      return hit||net;
    })
  );
});

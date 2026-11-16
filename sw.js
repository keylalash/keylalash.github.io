const CACHE='keyla-admin-push-v2';
self.addEventListener('install',e=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
self.addEventListener('push',e=>{let d={};try{d=e.data.json()}catch{d={title:'Keyla Lash',body:e.data?.text()||'Novo aviso'}}e.waitUntil(self.registration.showNotification(d.title||'Keyla Lash Admin',{body:d.body||'Novo aviso',icon:'./icon-192.png',badge:'./icon-192.png',tag:'keyla-'+Date.now(),data:{url:d.url||'./admin.html'}}))});
self.addEventListener('notificationclick',e=>{e.notification.close();const target=new URL(e.notification.data?.url||'./admin.html',self.registration.scope).href;e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(async cs=>{for(const c of cs){if(c.url.startsWith(self.registration.scope)){await c.focus();if(c.navigate)await c.navigate(target);return}}await self.clients.openWindow(target)}))});

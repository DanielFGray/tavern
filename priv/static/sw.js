// Tavern's service worker (docs/design/push-notifications.md). It only shows Web Push
// notifications and opens them. It has no fetch handler and caches nothing, so a deploy is
// never hidden behind a stale copy of the app.

self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()))

// Every push shows a notification: a browser revokes a subscription whose pushes show none.
self.addEventListener("push", event => {
  let data = {}
  try { data = event.data ? event.data.json() : {} } catch (_error) { data = {} }

  event.waitUntil(self.registration.showNotification(data.title || "Tavern", {
    body: data.body || "New message",
    tag: data.tag,
    icon: "/images/app-icon-192.png",
    data: {path: data.path || "/"},
  }))
})

// Focus an open Tavern tab and take it to the conversation, or open a new one.
self.addEventListener("notificationclick", event => {
  event.notification.close()
  const url = new URL(event.notification.data?.path || "/", self.location.origin).href

  event.waitUntil((async () => {
    const tabs = await self.clients.matchAll({type: "window", includeUncontrolled: true})
    const tab = tabs.find(client => new URL(client.url).origin === self.location.origin)

    if(tab) {
      await tab.focus()
      return tab.navigate(url).catch(() => self.clients.openWindow(url))
    }

    return self.clients.openWindow(url)
  })())
})

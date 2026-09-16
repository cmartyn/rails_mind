// Uses the application's Ahoy endpoint/cookies. Never put the server token here.
// Do not run alongside another automatic pageview handler.
const installations = new WeakMap()

export function start({ ahoy, document: doc = document, turbo = true, pageviews = true, frames = false,
  page = () => doc.querySelector('meta[name="rails-mind-page"]')?.content || "page" } = {}) {
  if (!ahoy || typeof ahoy.track !== "function") throw new TypeError("Pass the existing Ahoy instance")
  if (installations.has(doc)) return installations.get(doc)
  const listeners = []
  let visit = 0
  let trackedVisit = -1

  function on(name, listener) {
    doc.addEventListener(name, listener)
    listeners.push([name, listener])
  }

  function trackPage() {
    if (!pageviews || trackedVisit === visit || doc.documentElement.hasAttribute("data-turbo-preview")) return
    trackedVisit = visit
    ahoy.track("$pageview", { page: String(page()).slice(0, 160), navigation: turbo ? "turbo" : "document" })
  }

  if (turbo) {
    on("turbo:visit", () => { visit += 1 })
    on("turbo:load", trackPage)
  } else {
    on("DOMContentLoaded", trackPage)
  }
  // Supports loading the adapter after the initial page load, without duplicating
  // a subsequent turbo:load for that same initial navigation.
  if (doc.readyState === "complete") trackPage()

  if (frames) on("turbo:frame-load", (event) => {
    const label = event.target?.dataset?.analyticsFrame
    if (label) ahoy.track("$frame_view", { frame: String(label).slice(0, 100), page: String(page()).slice(0, 160) })
  })

  const api = {
    // The caller records a business outcome only after it actually succeeds.
    track: (name, properties = {}) => ahoy.track(name, properties),
    stop() {
      listeners.forEach(([name, listener]) => doc.removeEventListener(name, listener))
      installations.delete(doc)
    }
  }
  installations.set(doc, api)
  return api
}

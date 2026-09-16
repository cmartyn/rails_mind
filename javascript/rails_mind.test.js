import test from "node:test"
import assert from "node:assert/strict"
import { start } from "./rails_mind.js"

class Document extends EventTarget {
  readyState = "loading"
  preview = false
  documentElement = { hasAttribute: () => this.preview }
  querySelector() { return { content: "Invoices#index" } }
  emit(name, target) {
    const event = new Event(name)
    if (target) Object.defineProperty(event, "target", { value: target })
    this.dispatchEvent(event)
  }
}

test("Turbo previews, reload installation, Frames, and business outcomes stay distinct", () => {
  const document = new Document()
  const events = []
  const ahoy = { track: (name, properties) => events.push({ name, properties }) }
  const api = start({ ahoy, document, frames: true })
  assert.equal(start({ ahoy, document }), api)
  document.emit("DOMContentLoaded")
  document.emit("turbo:load")
  document.emit("turbo:load")
  assert.equal(events.length, 1)
  document.emit("turbo:visit")
  document.preview = true
  document.emit("turbo:render")
  document.emit("turbo:load")
  document.preview = false
  document.emit("turbo:render")
  document.emit("turbo:load")
  assert.equal(events.length, 2)
  document.emit("turbo:frame-load", { dataset: { analyticsFrame: "invoice-list" } })
  document.emit("turbo:frame-load", { dataset: {} })
  document.emit("turbo:submit-end")
  assert.equal(events.at(-1).name, "$frame_view")
  assert.equal(events.length, 3)
  api.track("Invoice paid", { amount_cents: 500 })
  assert.equal(events.at(-1).name, "Invoice paid")
  document.emit("turbo:visit") // Includes restoration visits.
  document.emit("turbo:load")
  assert.equal(events.filter(event => event.name === "$pageview").length, 3)
  api.stop()
  document.emit("turbo:visit")
  document.emit("turbo:load")
  assert.equal(events.length, 5)
})

test("Late start and initial Turbo load produce one pageview", () => {
  const document = new Document()
  document.readyState = "complete"
  const events = []
  start({ ahoy: { track: name => events.push(name) }, document })
  document.emit("turbo:load")
  document.emit("DOMContentLoaded")
  assert.deepEqual(events, ["$pageview"])
})

test("Existing pageview tracking can be preserved while explicit events remain usable", () => {
  const document = new Document()
  const events = []
  const api = start({ ahoy: { track: name => events.push(name) }, document, pageviews: false })
  document.emit("turbo:visit")
  document.emit("turbo:load")
  document.emit("turbo:frame-load")
  api.track("Trial started")
  assert.deepEqual(events, ["Trial started"])
})

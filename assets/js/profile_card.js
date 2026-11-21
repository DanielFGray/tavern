import { renderMarkdownIn } from "./chat_hooks"

// A trigger is any element that names a member: `data-profile-user-id` or `data-profile-username`.
const TRIGGER = "[data-profile-user-id], [data-profile-username]"
const ANCHOR_NAME = "--profile-trigger"
const OPEN_DELAY_MS = 300
const CLOSE_DELAY_MS = 150

// Opens the page's one profile card for a trigger: after a short hover, at once on a click, a tap
// or keyboard focus. The card closes on Escape, a click elsewhere, or when the pointer leaves both
// the trigger and the card. The hook gives the open trigger the anchor name the card's CSS
// positions against, and asks the server for the card; the server renders it.
export const ProfileCardHook = {
  mounted() {
    this.trigger = null
    this.openTimer = null
    this.closeTimer = null

    this.on(document, "mouseover", event => {
      const trigger = triggerOf(event.target)
      if(!trigger) return
      this.cancelClose()
      if(trigger !== this.trigger) this.openAfterDelay(trigger)
    })

    this.on(document, "mouseout", event => {
      const trigger = triggerOf(event.target)
      if(!trigger || trigger.contains(event.relatedTarget)) return
      this.cancelOpen()
      this.closeAfterDelay()
    })

    this.on(document, "focusin", event => {
      const trigger = triggerOf(event.target)
      if(trigger && trigger !== this.trigger) this.open(trigger)
    })

    this.on(document, "click", event => {
      const trigger = triggerOf(event.target)
      if(trigger) {
        // The click names a member; it is not also a click on the message row behind it.
        event.stopPropagation()
        this.open(trigger)
      } else if(this.trigger && !this.card()?.contains(event.target)) {
        this.close()
      }
    })

    this.on(document, "keydown", event => {
      if(event.key === "Escape" && this.trigger) this.close()
    })

    // The card is replaced by the server, so its pointer events are caught here.
    this.on(this.el, "mouseover", () => this.cancelClose())
    this.on(this.el, "mouseout", event => {
      if(!this.el.contains(event.relatedTarget)) this.closeAfterDelay()
    })
  },

  updated() {
    renderMarkdownIn(this.el)
  },

  destroyed() {
    this.cancelOpen()
    this.cancelClose()
    this.listeners.forEach(([target, type, handler]) => target.removeEventListener(type, handler))
  },

  on(target, type, handler) {
    this.listeners = this.listeners || []
    target.addEventListener(type, handler)
    this.listeners.push([target, type, handler])
  },

  card() {
    return this.el.querySelector("#profile-card")
  },

  openAfterDelay(trigger) {
    this.cancelOpen()
    this.openTimer = window.setTimeout(() => this.open(trigger), OPEN_DELAY_MS)
  },

  open(trigger) {
    this.cancelOpen()
    this.cancelClose()
    if(this.trigger !== trigger) {
      this.clearAnchor()
      trigger.style.setProperty("anchor-name", ANCHOR_NAME)
      this.trigger = trigger
    }

    const { profileUserId, profileUsername } = trigger.dataset
    this.pushEvent("show_profile", profileUserId ? { user_id: profileUserId } : { username: profileUsername })
  },

  close() {
    this.cancelOpen()
    this.cancelClose()
    this.clearAnchor()
    this.trigger = null
    this.pushEvent("hide_profile", {})
  },

  closeAfterDelay() {
    if(!this.trigger) return
    this.cancelClose()
    this.closeTimer = window.setTimeout(() => this.close(), CLOSE_DELAY_MS)
  },

  clearAnchor() {
    this.trigger?.style.removeProperty("anchor-name")
  },

  cancelOpen() {
    window.clearTimeout(this.openTimer)
    this.openTimer = null
  },

  cancelClose() {
    window.clearTimeout(this.closeTimer)
    this.closeTimer = null
  },
}

function triggerOf(target) {
  return target instanceof Element ? target.closest(TRIGGER) : null
}

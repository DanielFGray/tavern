// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import {MessageListHook, ReactionPickerHook, RichComposerHook} from "./chat_hooks"
import {ProfileCardHook} from "./profile_card"
import {hooks as colocatedHooks} from "phoenix-colocated/tavern"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    RichComposerHook,
    MessageListHook,
    ReactionPickerHook,
    ProfileCardHook,
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// The server pushes "static_changed" when this tab runs JS or CSS from an earlier build
// (TavernWeb.ReloadOnNewBuild). During a deploy the old and new servers can both answer for a
// moment, so a reloaded page can come from either and its socket reach the other, which reports a
// change again whichever build the page holds. A tab therefore reloads at most once a minute, and
// a change reported sooner reloads when that minute ends.
const BUILD_RELOAD_KEY = "tavern:build-reload-at"
const BUILD_RELOAD_INTERVAL_MS = 60_000
let pendingBuildReload = null

window.addEventListener("phx:static_changed", () => {
  let lastReloadAt
  try {
    lastReloadAt = Number(sessionStorage.getItem(BUILD_RELOAD_KEY)) || 0
  } catch {
    // Without storage the limit cannot hold, so the tab keeps its build rather than risk a loop.
    return
  }

  const wait = lastReloadAt + BUILD_RELOAD_INTERVAL_MS - Date.now()
  if(wait <= 0) reloadForNewBuild()
  else pendingBuildReload ??= window.setTimeout(reloadForNewBuild, wait)
})

function reloadForNewBuild() {
  try {
    sessionStorage.setItem(BUILD_RELOAD_KEY, String(Date.now()))
  } catch {
    return
  }
  window.location.reload()
}

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

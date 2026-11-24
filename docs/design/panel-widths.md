# Panel widths

A reader can drag the inner edge of four side panels to change their width. Each browser keeps
its own widths.

| Panel                | Name             | Docked from | Default | Min   | Max                 |
| -------------------- | ---------------- | ----------- | ------- | ----- | ------------------- |
| Channel list         | `channels`       | `xl`        | 16rem   | 12rem | min(28rem, 25vw)    |
| Member list          | `members`        | `xl`        | 15rem   | 12rem | min(24rem, 22vw)    |
| Voice channel chat   | `voice-chat`     | `lg`        | 24rem   | 16rem | min(40rem, 45vw)    |
| Thread browser       | `thread-browser` | `lg`        | 32rem   | 24rem | min(56rem, 80vw)    |

Below its breakpoint a panel is a fixed-width drawer or a full-width sheet, and it has no handle.

## How it works

- **The width is a CSS variable on `<html>`**, `--panel-<name>-w`. `<html>` is outside the
  LiveView patch root, so no re-render resets it. The panel's classes read it with the default
  as fallback: `xl:w-[var(--panel-channels-w,16rem)]`.
- **The panel's classes own the bounds.** Its `min-width` and `max-width` clamp the variable
  in CSS. The max depends on the viewport, so a width saved on a wide monitor still leaves room
  for the messages in a narrow window. The `.PanelResize` hook reads the bounds from the
  computed style, so the numbers exist only in the classes.
- **The hook** (`TavernWeb.ServerComponents.PanelResize`) sits on a `role="separator"` handle.
  - Pointer drag sets the variable as you move and saves it on release.
  - Arrow keys move the separator 16px, and Home and End go to the bounds (the WAI-ARIA window
    splitter pattern).
  - Double-click removes the variable and the saved value, so the default returns.
  - It writes `aria-valuenow`, `aria-valuemin` and `aria-valuemax` through LiveView JS
    commands, which keep them across patches.
- **Saved widths** live in localStorage under `tavern:panel-width:<name>`, in pixels. The
  nonce'd script in `root.html.heex` applies every such key before first paint, so the panels
  do not jump when the LiveView connects.

To make another panel resizable, give it an id, a `relative` position, the variable width and
bounds at its docked breakpoint, and a `resize_handle` on its inner edge.

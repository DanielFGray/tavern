// Composer drafts live in localStorage, one entry per user and conversation, so unsent text
// survives a reload (a deploy reloads open tabs) and waits in each channel or thread while the
// reader is elsewhere. The server names the entry in the form's `data-draft-key`.
//
// An entry holds the Tiptap document JSON rather than the markdown body, so mention, command and
// custom emoji nodes come back as nodes. A newer build always reads what an older build wrote,
// so a document the current schema rejects is discarded instead of restored.

const PREFIX = "tavern:draft:"

/** Replace the editor's content with the draft stored under `key`, or empty it when none is. */
export function restoreDraft(editor, key) {
  const stored = read(key)

  try {
    if(stored) {
      editor.commands.setContent(JSON.parse(stored), {emitUpdate: false, errorOnInvalidContent: true})
      return
    }
  } catch {
    discardDraft(key)
  }

  editor.commands.clearContent(false)
}

/** Store the editor's document under `key`, or remove the entry when the editor is empty. */
export function saveDraft(editor, key) {
  if(editor.isEmpty) {
    discardDraft(key)
    return
  }

  try {
    localStorage.setItem(PREFIX + key, JSON.stringify(editor.getJSON()))
  } catch {
    // Without storage the draft lives only as long as the page.
  }
}

export function discardDraft(key) {
  try {
    localStorage.removeItem(PREFIX + key)
  } catch {
    // Nothing was stored.
  }
}

function read(key) {
  try {
    return localStorage.getItem(PREFIX + key)
  } catch {
    return null
  }
}

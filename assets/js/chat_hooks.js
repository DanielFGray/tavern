import { Editor, Extension, Node } from "@tiptap/core"
import StarterKit from "@tiptap/starter-kit"
import Placeholder from "@tiptap/extension-placeholder"
import Mention from "@tiptap/extension-mention"
import Link from "@tiptap/extension-link"
import Suggestion from "@tiptap/suggestion"
import { PluginKey } from "@tiptap/pm/state"
import MarkdownIt from "markdown-it"
import DOMPurify from "dompurify"
import { highlightCode } from "./code_highlight"
import { emojiShortcodePlugin, searchEmojiShortcodes } from "./emoji_shortcodes"
import { CATEGORY_ICONS, CATEGORY_ORDER, CATEGORY_LABELS, filterEmojiCatalog } from "./emoji_catalog"
import { discardDraft, restoreDraft, saveDraft } from "./composer_drafts"

const md = new MarkdownIt({
  html: false,
  linkify: true,
  breaks: true,
  typographer: false,
  highlight: (code, language) => {
    const languageLabel = language
      ? `<span class="inline-flex px-[0.9rem] pt-[0.55rem] text-[10px] font-extrabold uppercase tracking-[0.18em] text-zinc-400">${escapeHtml(language)}</span>`
      : ""
    return `<div class="message-code-block overflow-hidden rounded-[0.9rem] border border-white/6 bg-[rgb(17_18_20_/_0.92)]">${languageLabel}<pre class="m-0 overflow-x-auto px-[0.95rem] pt-[0.85rem] pb-4"><code class="text-[13px] text-zinc-200">${highlightCode(code, language) ?? escapeHtml(code)}</code></pre></div>`
  },
})

md.use(emojiShortcodePlugin)

// Renders each `data-markdown-source` element under `root` as sanitised Markdown. Custom emoji
// arrive after the first render, so a body is drawn again when the root's emoji list changes.
export function renderMarkdownIn(root) {
  const emojiKey = root.dataset.customEmojis || ""
  const customEmojis = parseDatasetJson(emojiKey).custom || []

  root.querySelectorAll("[data-markdown-source]").forEach(node => {
    const source = node.dataset.markdownSource || ""
    if(node.dataset.renderedSource === source && node.dataset.renderedEmojis === emojiKey) return

    node.innerHTML = DOMPurify.sanitize(md.render(source, { customEmojis }))
    node.dataset.renderedSource = source
    node.dataset.renderedEmojis = emojiKey
  })
}

const LINK_ATTRIBUTES = [
  ["target", "_blank"],
  ["rel", "noopener noreferrer nofollow"],
  ["class", "text-blue-700 underline decoration-blue-700/40 underline-offset-2 hover:decoration-blue-700 dark:text-blue-300 dark:decoration-blue-300/40 dark:hover:decoration-blue-300"],
]

const defaultLinkRenderer = md.renderer.rules.link_open || ((tokens, idx, options, env, self) => self.renderToken(tokens, idx, options))
md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
  LINK_ATTRIBUTES.forEach(([name, value]) => tokens[idx].attrSet(name, value))
  return defaultLinkRenderer(tokens, idx, options, env, self)
}

// Markdown image syntax renders as a link to the image, never an <img>: a remote image would
// tell its host who reads the message, and the page's policy blocks other hosts anyway. The
// server shows a direct image link as a stored image card under the message instead. An image
// written inside a link is only its text, so anchors never nest.
md.renderer.rules.image = (tokens, idx, options, env, self) => {
  const token = tokens[idx]
  const src = token.attrGet("src") || ""
  const text = self.renderInlineAsText(token.children || [], options, env) || src
  if(insideLink(tokens, idx)) return escapeHtml(text)

  const attributes = [["href", src], ...LINK_ATTRIBUTES]
    .map(([name, value]) => `${name}="${escapeHtml(value)}"`)
    .join(" ")
  return `<a ${attributes}>${escapeHtml(text)}</a>`
}

// An @username in text becomes a trigger for the profile card. Any @name matches: the server shows
// a card only when the name belongs to a member, so a stray @word opens nothing. Text inside a
// link or code stays as written.
const MENTION_PATTERN = /(^|[^\w@/])@([a-z0-9_]{2,24})\b/g

md.core.ruler.after("inline", "profile_mentions", state => {
  for(const block of state.tokens) {
    if(block.type !== "inline" || !block.children) continue

    const children = []
    let linkDepth = 0
    for(const token of block.children) {
      if(token.type === "link_open") linkDepth++
      if(token.type === "link_close") linkDepth--
      if(token.type !== "text" || linkDepth > 0) {
        children.push(token)
        continue
      }
      children.push(...splitMentions(token.content, state.Token))
    }
    block.children = children
  }
})

function splitMentions(text, Token) {
  const tokens = []
  let last = 0
  for(const match of text.matchAll(MENTION_PATTERN)) {
    const start = match.index + match[1].length
    if(start > last) tokens.push(textToken(text.slice(last, start), Token))
    const mention = new Token("profile_mention", "", 0)
    mention.content = match[2]
    tokens.push(mention)
    last = start + match[2].length + 1
  }
  if(last < text.length) tokens.push(textToken(text.slice(last), Token))
  return tokens
}

function textToken(content, Token) {
  const token = new Token("text", "", 0)
  token.content = content
  return token
}

md.renderer.rules.profile_mention = (tokens, idx) => {
  const username = escapeHtml(tokens[idx].content)
  return `<span data-profile-username="${username}" tabindex="0" role="button" class="cursor-pointer rounded px-0.5 font-medium text-primary hover:bg-primary/15">@${username}</span>`
}

// Tiptap offers a key to extensions from the highest priority down, and the first handler that
// returns true takes it. Enter goes to an open @ or / suggestion list first, then to the send
// shortcut, then to the editor's core keymap (priority 100), which would split the paragraph.
const SUGGESTION_PRIORITY = 200
const SEND_PRIORITY = 150

const ComposerEntity = Mention.extend({
  priority: SUGGESTION_PRIORITY,

  addAttributes() {
    return {
      ...this.parent?.(),
      entityType: {
        default: null,
        parseHTML: element => element.getAttribute("data-entity-type"),
        renderHTML: attributes => {
          if(!attributes.entityType) return {}
          return { "data-entity-type": attributes.entityType }
        },
      },
    }
  },

  renderText({ node }) {
    const prefix = node.attrs.mentionSuggestionChar === "/" ? "/" : "@"
    return `${prefix}${node.attrs.label ?? node.attrs.id}`
  },

  renderHTML({ node, HTMLAttributes }) {
    const isSlashCommand = node.attrs.mentionSuggestionChar === "/"

    return [
      "span",
      {
        ...HTMLAttributes,
        "data-entity-type": node.attrs.entityType || (isSlashCommand ? "slash_command" : "mention"),
        class: isSlashCommand
          ? "inline-flex items-center rounded-full bg-violet-500/18 px-2 py-0.5 text-[0.85em] font-bold text-violet-800 dark:text-violet-200"
          : "inline-flex items-center rounded-full bg-blue-500/18 px-2 py-0.5 text-[0.85em] font-bold text-blue-800 dark:text-blue-200",
      },
      `${isSlashCommand ? "/" : "@"}${node.attrs.label ?? node.attrs.id}`,
    ]
  },
})

// A custom server emoji in the composer: one atomic inline image, so Backspace removes the whole
// emoji. It serializes to `<:name:id>`; the id survives a rename of the emoji.
const CustomEmoji = Node.create({
  name: "customEmoji",
  group: "inline",
  inline: true,
  atom: true,
  selectable: false,

  addAttributes() {
    return { id: { default: null }, name: { default: "" }, url: { default: "" } }
  },

  parseHTML() {
    return [{ tag: "img[data-custom-emoji-id]", getAttrs: el => ({ id: el.getAttribute("data-custom-emoji-id"), name: el.getAttribute("alt")?.replace(/^:|:$/g, ""), url: el.getAttribute("src") }) }]
  },

  renderHTML({ node }) {
    return ["img", {
      "data-custom-emoji-id": node.attrs.id,
      src: node.attrs.url,
      alt: `:${node.attrs.name}:`,
      title: `:${node.attrs.name}:`,
      draggable: "false",
      class: "inline-block h-[1.375em] w-[1.375em] align-[-0.3em] object-contain",
    }]
  },

  renderText({ node }) {
    return `<:${node.attrs.name}:${node.attrs.id}>`
  },
})

// Typing `:` and two letters opens a list of emoji. A unicode pick is inserted as the emoji
// itself; a custom pick as a customEmoji node.
const EmojiShortcode = Extension.create({
  name: "emojiShortcode",
  priority: SUGGESTION_PRIORITY,

  addOptions() {
    return { customEmojis: () => [] }
  },

  addProseMirrorPlugins() {
    const { customEmojis } = this.options

    return [
      Suggestion({
        editor: this.editor,
        pluginKey: new PluginKey("emojiShortcodeSuggestion"),
        ...buildSuggestion({
          char: ":",
          items: query => searchEmojiShortcodes(query, customEmojis()),
          filter: false,
          emptyText: null,
          renderOption: emojiOption,
        }),
        command: ({ editor, range, props }) => {
          const content = props.native
            ? { type: "text", text: props.native }
            : { type: "customEmoji", attrs: { id: props.id, name: props.name, url: props.url } }
          editor.chain().focus().insertContentAt(range, [content, { type: "text", text: " " }]).run()
        },
      }),
    ]
  },
})

function emojiOption(item) {
  const glyph = item.native
    ? `<span class="w-6 text-center text-[1.15rem] leading-none">${escapeHtml(item.native)}</span>`
    : `<img class="h-6 w-6 object-contain" src="${escapeHtml(item.url)}" alt="">`

  return `<span class="flex items-center gap-2.5">${glyph}<span class="text-[0.86rem] font-bold text-zinc-100">:${escapeHtml(item.name)}:</span></span>`
}

const RichComposerHook = {
  mounted() {
    this.bodyInput = this.el.querySelector("[data-rich-composer-body]")
    this.metadataInput = this.el.querySelector("[data-rich-composer-metadata]")
    this.editorElement = this.el.querySelector("[data-rich-composer-editor]")
    this.toolbar = this.el.querySelector("[data-rich-composer-toolbar]")
    this.composerShell = this.el.querySelector("[data-rich-composer-shell]")
    this.composerTarget = this.el.dataset.composerTarget || "default"
    this.draftKey = this.el.dataset.draftKey
    this.submitListener = () => this.syncInputs()
    this.typingStopDelayMs = 4000
    this.typingActive = false
    this.typingStopTimer = null
    this.lastTypingPingTime = 0
    this.typingPingThrottleMs = 3000
    this.editor = this.buildEditor()

    if(this.toolbar) {
      this.toolbar.addEventListener("click", this.handleToolbarClick)
    }

    this.el.addEventListener("submit", this.submitListener)

    // The reader may have moved to another conversation before the send was acknowledged, so the
    // sent conversation's draft is dropped either way and this editor empties only if it shows it.
    this.handleEvent("composer:clear", ({draft_key}) => {
      discardDraft(draft_key)
      if(draft_key !== this.draftKey) return

      this.editor.commands.clearContent(true)
      this.syncInputs()
      this.syncComposerChrome()
      this.stopTyping()
      this.editor.commands.focus("end")
    })

    this.showDraft()
  },

  // A channel or thread switch can keep this form mounted and only change its draft key. The
  // outgoing draft is already saved, since every edit saves it.
  updated() {
    const key = this.el.dataset.draftKey
    if(key === this.draftKey) return

    this.draftKey = key
    this.showDraft()
  },

  destroyed() {
    if(this.toolbar) {
      this.toolbar.removeEventListener("click", this.handleToolbarClick)
    }

    this.el.removeEventListener("submit", this.submitListener)

    this.stopTyping()
    this.clearTypingStopTimer()

    this.editor?.destroy()
  },

  buildEditor() {
    this.handleToolbarClick = event => {
      const actionButton = event.target.closest("[data-editor-action]")
      if(!actionButton) return

      event.preventDefault()
      const action = actionButton.dataset.editorAction

      switch(action) {
        case "bold":
          this.editor.chain().focus().toggleBold().run()
          break
        case "italic":
          this.editor.chain().focus().toggleItalic().run()
          break
        case "inline-code":
          this.editor.chain().focus().toggleCode().run()
          break
        case "code-block":
          this.editor.chain().focus().toggleCodeBlock().run()
          break
        case "mention":
          this.editor.chain().focus().insertContent("@").run()
          break
        case "slash":
          this.editor.chain().focus().insertContent("/").run()
          break
        default:
          break
      }
    }

    return new Editor({
      element: this.editorElement,
      extensions: [
        StarterKit.configure({
          heading: false,
          blockquote: false,
          horizontalRule: false,
          strike: false,
          link: false,
        }),
        // Enter sends; Shift+Enter is StarterKit's hard break, a new line in the message.
        Extension.create({
          name: "submitOnEnter",
          priority: SEND_PRIORITY,
          addKeyboardShortcuts: () => ({
            Enter: ({ editor }) => {
              if(editor.isActive("codeBlock") || editor.isEmpty) return false
              this.el.requestSubmit()
              return true
            },
          }),
        }),
        Placeholder.configure({
          placeholder: this.el.dataset.placeholder || "Message channel",
        }),
        Link.configure({
          autolink: true,
          openOnClick: false,
          protocols: ["http", "https"],
        }),
        CustomEmoji,
        EmojiShortcode.configure({
          customEmojis: () => parseDatasetJson(this.el.dataset.customEmojis).custom || [],
        }),
        ComposerEntity.configure({
          suggestions: [
            buildSuggestion({
              char: "@",
              items: () => parseDatasetJson(this.el.dataset.mentions).map(item => ({ ...item, entityType: item.type || "mention" })),
            }),
            buildSuggestion({
              char: "/",
              startOfLine: true,
              items: () => parseDatasetJson(this.el.dataset.commands).map(item => ({ ...item, entityType: "slash_command" })),
            }),
          ],
        }),
      ],
      editorProps: {
        attributes: {
          class: [
            "ProseMirror min-h-6 whitespace-pre-wrap break-words text-[15px] leading-6 text-base-content outline-none",
            "[&>p]:m-0",
            "[&_p.is-editor-empty:first-child::before]:pointer-events-none",
            "[&_p.is-editor-empty:first-child::before]:float-left",
            "[&_p.is-editor-empty:first-child::before]:h-0",
            "[&_p.is-editor-empty:first-child::before]:text-base-content/40",
            "[&_p.is-editor-empty:first-child::before]:content-[attr(data-placeholder)]",
            "[&_code]:rounded-md [&_code]:bg-[rgba(17,18,20,0.75)] [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:text-[0.88em] [&_code]:text-zinc-100",
            "[&_pre]:mt-2 [&_pre]:overflow-x-auto [&_pre]:rounded-xl [&_pre]:bg-[rgb(17_18_20)] [&_pre]:px-4 [&_pre]:py-3.5",
            "[&_pre_code]:bg-transparent [&_pre_code]:p-0"
          ].join(" "),
          spellcheck: "true",
        },
      },
      autofocus: false,
      onCreate: () => {
        this.syncInputs()
        this.syncComposerChrome()
      },
      onUpdate: () => {
        saveDraft(this.editor, this.draftKey)
        this.syncInputs()
        this.syncComposerChrome()
        this.handleTypingActivity()
      },
      onTransaction: ({ editor }) => {
        syncToolbarState(this.toolbar, editor)
      },
      onFocus: () => {
        this.syncComposerChrome()
      },
      onBlur: () => {
        requestAnimationFrame(() => this.syncComposerChrome())
      },
    })
  },

  showDraft() {
    restoreDraft(this.editor, this.draftKey)
    this.syncInputs()
    this.syncComposerChrome()
  },

  syncInputs() {
    if(!this.bodyInput || !this.metadataInput || !this.editor) return

    const json = this.editor.getJSON()
    this.bodyInput.value = serializeMarkdown(json).trim()
    this.metadataInput.value = JSON.stringify({
      composer: "tiptap",
      entities: collectEntities(json),
      document: json,
    })

    this.bodyInput.dispatchEvent(new Event("input", { bubbles: true }))
    this.metadataInput.dispatchEvent(new Event("input", { bubbles: true }))
  },

  syncComposerChrome() {
    if(!this.composerShell || !this.editor) return

    const isExpanded = this.editor.isFocused || !this.editor.isEmpty
    this.composerShell.classList.toggle("is-focused", this.editor.isFocused)
    this.composerShell.classList.toggle("is-expanded", isExpanded)

    this.composerShell.querySelectorAll("[data-expanded]").forEach(node => {
      node.dataset.expanded = isExpanded ? "true" : "false"
    })
  },

  handleTypingActivity() {
    const hasText = (this.bodyInput?.value || "").trim().length > 0

    if(!hasText) {
      this.stopTyping()
      return
    }

    const now = Date.now()
    if(now - this.lastTypingPingTime >= this.typingPingThrottleMs) {
      this.pushEvent(this.typingPingEvent(), {})
      this.lastTypingPingTime = now
      this.typingActive = true
    }

    this.clearTypingStopTimer()
    this.typingStopTimer = window.setTimeout(() => this.stopTyping(), this.typingStopDelayMs)
  },

  stopTyping() {
    if(!this.typingActive) return

    this.pushEvent(this.typingStopEvent(), {})
    this.typingActive = false
    this.clearTypingStopTimer()
  },

  clearTypingStopTimer() {
    if(this.typingStopTimer) {
      window.clearTimeout(this.typingStopTimer)
      this.typingStopTimer = null
    }
  },

  typingPingEvent() {
    return this.composerTarget === "thread" ? "typing_ping_thread" : "typing_ping"
  },

  typingStopEvent() {
    return this.composerTarget === "thread" ? "typing_stop_thread" : "typing_stop"
  },
}

// The server pushes "entered" with the DOM ids of things that arrived while the reader watches (a
// live message, an opened thread panel, a new thread pill). Loads, channel switches and restored
// threads never send it. Only transform and opacity change, so layout and scroll anchoring stay
// as they are. The channel list and the thread list hooks both receive the event, so a node is
// animated once.
const ENTER_MS = 180
const entered = new WeakSet()

function animateEntered(ids) {
  if(window.matchMedia("(prefers-reduced-motion: reduce)").matches) return

  ids.forEach(id => {
    const node = document.getElementById(id)
    if(!node || entered.has(node)) return

    entered.add(node)
    node.animate(
      [{opacity: 0, transform: "translateY(6px)"}, {opacity: 1, transform: "none"}],
      {duration: ENTER_MS, easing: "ease-out"},
    )
  })
}

const MessageListHook = {
  mounted() {
    this.handleEvent("entered", ({ids}) => animateEntered(ids))
    this.autoscrollThreshold = 96
    this.shouldStickToBottom = true
    this.lastScrollHeight = this.el.scrollHeight
    this.onScroll = () => {
      this.shouldStickToBottom = this.isNearBottom()
    }

    this.el.addEventListener("scroll", this.onScroll)
    this.renderMarkdownBodies()

    if(this.el.dataset.enableNotifications !== "false") {
      this.handleEvent("notify:mention", payload => this.showMentionNotification(payload))
      this.handleEvent("notifications:request-permission", () => this.requestNotificationPermission())
    }

    requestAnimationFrame(() => this.scrollToBottom())
  },

  beforeUpdate() {
    this.anchor = this.measureAnchor()
  },

  updated() {
    const grew = this.el.scrollHeight > this.lastScrollHeight
    this.renderMarkdownBodies()
    const list = this.messageList()

    if(!list) {
      // A thread's own list is not a scroll box; only the channel list anchors.
      if(grew && this.shouldStickToBottom) requestAnimationFrame(() => this.scrollToBottom())
    } else if(this.anchor && list.lastElementChild?.id !== this.anchor.tailId && this.shouldStickToBottom) {
      // A message arrived at the end of the channel while the view was at the bottom: follow it.
      requestAnimationFrame(() => this.scrollToBottom())
    } else {
      // Anything else that changes the height (a thread panel opening, closing or taking a reply)
      // must not move what the reader is looking at.
      this.restoreAnchor()
      this.revealOpenedThread()
    }

    this.lastScrollHeight = this.el.scrollHeight
  },

  // The first channel row that reaches into the viewport, with its distance from the viewport top.
  measureAnchor() {
    const list = this.messageList()
    if(!list) return null

    const top = this.el.getBoundingClientRect().top
    const row = Array.from(list.children).find(child => child.getBoundingClientRect().bottom > top)
    return {
      tailId: list.lastElementChild?.id,
      rowId: row?.id,
      offset: row ? row.getBoundingClientRect().top - top : 0,
      threadId: this.openThreadId(),
    }
  },

  restoreAnchor() {
    if(!this.anchor?.rowId) return
    const row = document.getElementById(this.anchor.rowId)
    if(!row) return

    const offset = row.getBoundingClientRect().top - this.el.getBoundingClientRect().top
    this.el.scrollTop += offset - this.anchor.offset
    this.shouldStickToBottom = this.isNearBottom()
  },

  // A thread that just opened scrolls into view only as far as its header, never to the composer.
  revealOpenedThread() {
    const id = this.openThreadId()
    if(!id || id === this.anchor?.threadId) return

    const header = document.getElementById(id)?.querySelector("header")
    if(!header) return

    const hidden = header.getBoundingClientRect().bottom - this.el.getBoundingClientRect().bottom
    if(hidden > 0) this.el.scrollTop += hidden
  },

  messageList() {
    return this.el.querySelector(":scope > #message-list")
  },

  openThreadId() {
    return this.messageList()?.querySelector('[id^="thread-panel-"]')?.id
  },

  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll)
  },

  renderMarkdownBodies() {
    renderMarkdownIn(this.el)
  },

  isNearBottom() {
    const remaining = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
    return remaining <= this.autoscrollThreshold
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  },

  showMentionNotification(payload) {
    if(typeof window === "undefined" || typeof Notification === "undefined") return
    if(document.visibilityState === "visible") return
    if(Notification.permission !== "granted") return

    const bodyPreview = (payload.body || "").trim().slice(0, 140) || "You were mentioned in a message"
    const channelName = payload.channel_name ? `#${payload.channel_name}` : "another channel"

    const notification = new Notification(`${payload.author_name} mentioned you in ${channelName}`, {
      body: bodyPreview,
      tag: `mention-${payload.message_id}`,
    })

    notification.onclick = () => {
      window.focus()
      notification.close()
    }
  },

  requestNotificationPermission() {
    if(typeof window === "undefined" || typeof Notification === "undefined") return
    if(Notification.permission !== "default") return

    Notification.requestPermission().catch(() => {})
  },
}

const ReactionPickerHook = {
  mounted() {
    this.searchInput = this.el.querySelector("[data-reaction-picker-search]")
    this.defaultsContainer = this.el.querySelector("[data-reaction-picker-defaults]")
    this.categoriesContainer = this.el.querySelector("[data-reaction-picker-categories]")
    this.customContainer = this.el.querySelector("[data-reaction-picker-custom]")
    this.messageId = this.defaultsContainer?.dataset.messageId
    this.activeCategory = null
    this.query = ""

    this.customEmojiDataset = parseDatasetJson(this.el.dataset.customEmojis)
    this.customEmojiIds = new Set((this.customEmojiDataset.custom || []).map(item => item.id))
    this.branding = this.customEmojiDataset.branding || {}

    this.handleSearch = event => {
      this.query = event.target.value || ""
      this.renderCatalog()
    }

    this.handleCategoryClick = event => {
      const button = event.target.closest("[data-reaction-picker-category]")
      if(!button) return
      event.preventDefault()

      const nextCategory = button.dataset.reactionPickerCategory || null
      this.activeCategory = this.activeCategory === nextCategory ? null : nextCategory
      this.renderCatalog()
    }

    this.searchInput?.addEventListener("input", this.handleSearch)
    this.categoriesContainer?.addEventListener("click", this.handleCategoryClick)
    this.renderCatalog()
    this.searchInput?.focus()
  },

  updated() {
    this.customEmojiDataset = parseDatasetJson(this.el.dataset.customEmojis)
    this.customEmojiIds = new Set((this.customEmojiDataset.custom || []).map(item => item.id))
    this.branding = this.customEmojiDataset.branding || {}
    this.renderCatalog()
  },

  destroyed() {
    this.searchInput?.removeEventListener("input", this.handleSearch)
    this.categoriesContainer?.removeEventListener("click", this.handleCategoryClick)
  },

  renderCatalog() {
    if(!this.defaultsContainer || !this.categoriesContainer || !this.messageId) return

    const items = this.activeCategory === "custom" ? [] : filterEmojiCatalog(this.query, this.activeCategory)
    this.renderCategories(items)
    this.renderDefaults(items)
    this.filterCustomEmojis()
  },

  renderCategories(items) {
    const availableCategories = new Set(items.map(item => item.category))

    this.categoriesContainer.innerHTML = ""

    CATEGORY_ORDER.forEach(categoryId => {
      if(this.query && !availableCategories.has(categoryId)) return

      const button = document.createElement("button")
      button.type = "button"
      button.dataset.reactionPickerCategory = categoryId
      button.title = CATEGORY_LABELS[categoryId] || categoryId
      button.setAttribute("aria-label", CATEGORY_LABELS[categoryId] || categoryId)
      button.className = [
        "flex size-10 items-center justify-center rounded-2xl border text-lg transition",
        this.activeCategory === categoryId
          ? "border-primary/50 bg-primary/15 text-primary shadow-[0_8px_24px_rgba(139,92,246,0.18)]"
          : "border-base-300 bg-base-200 text-base-content/65 hover:border-base-content/15 hover:bg-base-300 hover:text-base-content",
      ].join(" ")
      button.textContent = CATEGORY_ICONS[categoryId] || "•"
      this.categoriesContainer.appendChild(button)
    })

    if(this.customContainer && this.customContainer.children.length > 0) {
      const customButton = document.createElement("button")
      customButton.type = "button"
      customButton.dataset.reactionPickerCategory = "custom"
      customButton.title = "Custom emoji"
      customButton.setAttribute("aria-label", "Custom emoji")
      customButton.className = [
        "order-first mb-1 flex size-10 items-center justify-center overflow-hidden rounded-2xl border text-lg transition",
        this.activeCategory === "custom"
          ? "border-primary/50 bg-primary/15 text-primary shadow-[0_8px_24px_rgba(139,92,246,0.18)]"
          : "border-base-300 bg-base-200 text-base-content/65 hover:border-base-content/15 hover:bg-base-300 hover:text-base-content",
      ].join(" ")

      if(this.branding.icon_url) {
        const image = document.createElement("img")
        image.src = this.branding.icon_url
        image.alt = this.branding.name || "Server"
        image.className = "size-6 rounded-lg object-cover"
        customButton.appendChild(image)
      } else {
        customButton.textContent = "★"
      }

      this.categoriesContainer.prepend(customButton)
    }
  },

  renderDefaults(items) {
    this.defaultsContainer.innerHTML = ""

    if(items.length === 0) {
      const empty = document.createElement("p")
      empty.className = "col-span-8 rounded-2xl border border-dashed border-base-300 bg-base-200 px-3 py-4 text-center text-xs text-base-content/50"
      empty.textContent = "No default emojis match that search."
      this.defaultsContainer.appendChild(empty)
      return
    }

    items.forEach(entry => {
      const button = document.createElement("button")
      button.type = "button"
      button.setAttribute("phx-click", "toggle_reaction")
      button.setAttribute("phx-value-id", this.messageId)
      button.setAttribute("phx-value-emoji", entry.emoji)
      button.id = `reaction-picker-default-${this.messageId}-${entry.unified}`
      button.className = "flex aspect-square size-10 items-center justify-center rounded-xl text-xl transition hover:bg-base-200 md:size-9 md:text-lg"
      button.title = entry.name
      button.setAttribute("aria-label", entry.name)
      button.textContent = entry.emoji
      this.defaultsContainer.appendChild(button)
    })
  },

  filterCustomEmojis() {
    if(!this.customContainer) return

    const normalizedQuery = this.query.trim().toLowerCase()
    const customOnly = this.activeCategory === "custom"

    this.customContainer.closest("div")?.classList.toggle("hidden", this.activeCategory && !customOnly)
    this.defaultsContainer.closest("div")?.classList.toggle("hidden", customOnly)

    this.customContainer.querySelectorAll("[data-custom-emoji-id]").forEach(node => {
      const name = (node.dataset.customEmojiName || "").toLowerCase()
      const shortcode = (node.dataset.customEmojiShortcode || "").toLowerCase()
      const visible = normalizedQuery === "" || name.includes(normalizedQuery) || shortcode.includes(normalizedQuery)
      node.classList.toggle("hidden", !visible)
    })
  },
}

// `items` returns the candidates, filtered by label here unless `filter` is false. `renderOption`
// gives a row's HTML, `emptyText` is shown when nothing matches (null hides the list), and a
// row's item is passed whole to the suggestion's command.
function buildSuggestion({
  char,
  items,
  startOfLine = false,
  filter = true,
  emptyText = "No matches",
  renderOption = mentionOption(char),
}) {
  const choose = item => (filter ? { id: item.id, label: item.label } : item)

  return {
    char,
    startOfLine,
    items: ({ query }) => (filter ? filterItems(items(), query) : items(query)),
    render: () => {
      let popup
      let selectedIndex = 0
      let activeItems = []
      let command = null

      const renderPopup = props => {
        if(!popup) return

        activeItems = props.items
        popup.innerHTML = ""
        popup.hidden = activeItems.length === 0 && emptyText === null

        if(activeItems.length === 0) {
          if(emptyText !== null) popup.innerHTML = `<div class="flex w-full flex-col gap-0.5 px-[0.85rem] py-[0.7rem] text-left text-[0.72rem] text-zinc-400">${emptyText}</div>`
          return
        }

        activeItems.forEach((item, index) => {
          const option = document.createElement("button")
          option.type = "button"
          option.className = [
            "flex w-full flex-col gap-0.5 px-[0.85rem] py-[0.7rem] text-left transition",
            index === selectedIndex ? "bg-white/6" : "bg-transparent hover:bg-white/6",
          ].join(" ")
          option.innerHTML = renderOption(item)
          option.addEventListener("mousedown", event => {
            event.preventDefault()
            props.command(choose(item))
          })
          popup.appendChild(option)
        })
      }

      const reposition = props => {
        if(!popup || !props.clientRect) return
        const rect = props.clientRect()
        if(!rect) return

        // Viewport coordinates: the composer sits at the bottom of the screen, so the list opens
        // above the caret when it would run off the bottom.
        const gap = 8
        const { width, height } = popup.getBoundingClientRect()
        const fitsBelow = rect.bottom + gap + height <= window.innerHeight
        popup.style.left = `${Math.max(gap, Math.min(rect.left, window.innerWidth - width - gap))}px`
        popup.style.top = `${fitsBelow ? rect.bottom + gap : Math.max(gap, rect.top - gap - height)}px`
      }

      return {
        onStart: props => {
          selectedIndex = 0
          command = props.command
          popup = document.createElement("div")
          popup.className = "fixed z-80 min-w-60 max-w-80 overflow-hidden rounded-[0.9rem] border border-white/8 bg-[rgb(17_18_20_/_0.97)] shadow-[0_18px_40px_rgba(0,0,0,0.35)]"
          document.body.appendChild(popup)
          renderPopup(props)
          reposition(props)
        },
        onUpdate: props => {
          selectedIndex = 0
          command = props.command
          renderPopup(props)
          reposition(props)
        },
        onKeyDown: props => {
          if(props.event.key === "Escape") {
            popup?.remove()
            return true
          }

          if(props.event.key === "ArrowDown") {
            selectedIndex = (selectedIndex + 1) % Math.max(activeItems.length, 1)
            renderPopup(props)
            return true
          }

          if(props.event.key === "ArrowUp") {
            selectedIndex = (selectedIndex - 1 + Math.max(activeItems.length, 1)) % Math.max(activeItems.length, 1)
            renderPopup(props)
            return true
          }

          if(props.event.key === "Enter" && activeItems[selectedIndex]) {
            command(choose(activeItems[selectedIndex]))
            return true
          }

          return false
        },
        onExit: () => {
          popup?.remove()
          popup = null
        },
      }
    },
  }
}

function mentionOption(char) {
  return item => `
    <span class="text-[0.86rem] font-bold text-zinc-100">${char}${escapeHtml(item.label)}</span>
    <span class="text-[0.72rem] text-zinc-400">${escapeHtml(item.description || "")}</span>
  `
}

function filterItems(items, query) {
  const normalizedQuery = query.trim().toLowerCase()

  return items
    .filter(item => {
      if(normalizedQuery === "") return true
      return item.label.toLowerCase().includes(normalizedQuery)
    })
    .slice(0, 6)
}

function parseDatasetJson(value) {
  try {
    return JSON.parse(value || "[]")
  } catch (_error) {
    return []
  }
}

function serializeMarkdown(node, depth = 0) {
  if(!node) return ""

  if(node.type === "doc") {
    return normalizeSerializedMarkdown((node.content || []).map(child => serializeMarkdown(child, depth)).join(""))
  }

  switch(node.type) {
    case "paragraph": {
      const content = (node.content || []).map(child => serializeMarkdown(child, depth)).join("")
      return `${content}\n\n`
    }

    case "text":
      return applyMarks(node.text || "", node.marks || [])

    case "hardBreak":
      return "\n"

    case "customEmoji":
      return `<:${node.attrs?.name}:${node.attrs?.id}>`

    case "mention": {
      const prefix = node.attrs?.mentionSuggestionChar === "/" ? "/" : "@"
      return `${prefix}${node.attrs?.label || node.attrs?.id || ""}`
    }

    case "codeBlock": {
      const code = collectPlainText(node)
      return `\n\n\`\`\`${node.attrs?.language || ""}\n${code}\n\`\`\`\n\n`
    }

    case "bulletList":
      return (node.content || []).map(child => serializeListItem(child, "-", depth)).join("") + "\n"

    case "orderedList":
      return (node.content || []).map((child, index) => serializeListItem(child, `${index + 1}.`, depth)).join("") + "\n"

    default:
      return (node.content || []).map(child => serializeMarkdown(child, depth)).join("")
  }
}

function serializeListItem(node, bullet, depth) {
  const itemContent = (node.content || []).map(child => serializeMarkdown(child, depth + 1)).join("").trim()
  const indent = "  ".repeat(depth)
  const normalized = itemContent.replace(/\n{2,}/g, "\n").split("\n").join(`\n${indent}  `)
  return `${indent}${bullet} ${normalized}\n`
}

function applyMarks(text, marks) {
  return marks.reduce((content, mark) => {
    switch(mark.type) {
      case "bold":
        return `**${content}**`
      case "italic":
        return `*${content}*`
      case "code":
        return `\`${content}\``
      case "link":
        return `[${content}](${mark.attrs?.href || "#"})`
      default:
        return content
    }
  }, text)
}

function collectPlainText(node) {
  if(!node) return ""
  if(node.type === "text") return node.text || ""
  return (node.content || []).map(collectPlainText).join("")
}

function collectEntities(node, entities = []) {
  if(!node) return entities

  if(node.type === "mention") {
    entities.push({
      type: node.attrs?.entityType || (node.attrs?.mentionSuggestionChar === "/" ? "slash_command" : "mention"),
      id: node.attrs?.id,
      label: node.attrs?.label,
    })
  }

  ;(node.content || []).forEach(child => collectEntities(child, entities))
  return entities
}

function normalizeSerializedMarkdown(markdown) {
  return markdown
    .replace(/\n{3,}/g, "\n\n")
    .replace(/(?:\n\s*)+$/g, "")
}

function syncToolbarState(toolbar, editor) {
  if(!toolbar) return

  toolbar.querySelectorAll("[data-editor-action]").forEach(button => {
    const action = button.dataset.editorAction
    const active =
      (action === "bold" && editor.isActive("bold")) ||
      (action === "italic" && editor.isActive("italic")) ||
      (action === "inline-code" && editor.isActive("code")) ||
      (action === "code-block" && editor.isActive("codeBlock"))

    button.classList.toggle("is-active", !!active)
    button.dataset.active = active ? "true" : "false"
  })
}

function escapeHtml(value) {
  return `${value}`
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
}

// Whether the inline token at `idx` sits between a link_open and its link_close.
function insideLink(tokens, idx) {
  let depth = 0
  for(let i = 0; i < idx; i++) {
    if(tokens[i].type === "link_open") depth++
    if(tokens[i].type === "link_close") depth--
  }
  return depth > 0
}

export { MessageListHook, ReactionPickerHook, RichComposerHook }

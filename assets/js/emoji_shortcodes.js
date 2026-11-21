import emojiMartData from "@emoji-mart/data"

// :shortcode: emoji. Unicode emoji are stored as the character itself, or typed as `:name:` text
// that the browser draws. A custom server emoji is stored as `<:name:id>`: the id keeps old
// messages intact when the emoji is renamed. Unicode names come from emoji-mart's catalog.

const SHORTCODE = /^:([a-z0-9_+-]+):/
const CUSTOM_EMOJI_TOKEN = /^<:([a-z0-9_+-]+):([0-9a-f-]{36})>/
const MAX_SUGGESTIONS = 8
const MIN_QUERY_LENGTH = 2

const unicodeEntries = buildUnicodeEntries()
const unicodeByName = new Map(unicodeEntries.map(entry => [entry.name, entry]))

for(const [alias, id] of Object.entries(emojiMartData.aliases || {})) {
  const target = unicodeByName.get(id)
  if(target && !unicodeByName.has(alias)) unicodeByName.set(alias, { ...target, name: alias })
}

// markdown-it plugin: turns a known `:name:` into an emoji token. Unknown names, and anything
// inside code, stay text. Custom emoji come from `env.customEmojis` on each render call.
function emojiShortcodePlugin(md) {
  md.inline.ruler.before("emphasis", "emoji_shortcode", (state, silent) => {
    const code = state.src.charCodeAt(state.pos)
    if(code !== 0x3a && code !== 0x3c) return false

    const rest = state.src.slice(state.pos)
    const tokenMatch = code === 0x3c ? CUSTOM_EMOJI_TOKEN.exec(rest) : null
    const match = tokenMatch || (code === 0x3a ? SHORTCODE.exec(rest) : null)
    if(!match) return false

    // A `<:name:id>` whose emoji was deleted falls back to its `:name:` text.
    const custom = tokenMatch && state.env?.customEmojis?.find(emoji => emoji.id === tokenMatch[2])
    const emoji = tokenMatch
      ? (custom ? { url: custom.url, name: bareName(custom.shortcode) } : null)
      : resolveShortcode(match[1], state.env?.customEmojis)

    if(tokenMatch && !emoji) {
      if(!silent) state.push("text", "", 0).content = `:${match[1]}:`
      state.pos += match[0].length
      return true
    }
    if(!emoji) return false

    if(!silent) {
      const token = state.push("emoji_shortcode", "", 0)
      token.content = emoji.name || match[1]
      token.meta = emoji
    }

    state.pos += match[0].length
    return true
  })

  md.renderer.rules.emoji_shortcode = (tokens, idx) => {
    const { native, url } = tokens[idx].meta
    const label = `:${tokens[idx].content}:`

    if(native) return `<span class="emoji" role="img" aria-label="${escapeAttribute(label)}" title="${escapeAttribute(label)}">${native}</span>`
    return `<img class="emoji inline-block h-[1.375em] w-[1.375em] align-[-0.3em] object-contain" src="${escapeAttribute(url)}" alt="${escapeAttribute(label)}" title="${escapeAttribute(label)}" draggable="false">`
  }
}

// Emoji that match a typed query, best first: names that start with it, then names and
// keywords that contain it. Returns nothing until the query is long enough to mean something.
function searchEmojiShortcodes(query, customEmojis = []) {
  const needle = query.trim().toLowerCase()
  if(needle.length < MIN_QUERY_LENGTH) return []

  const custom = customEmojis.map(emoji => ({
    name: bareName(emoji.shortcode),
    keywords: [emoji.name || ""],
    url: emoji.url,
    id: emoji.id,
  }))

  const ranked = [...custom, ...unicodeEntries]
    .map(entry => ({ entry, rank: rankEntry(entry, needle) }))
    .filter(({ rank }) => rank !== null)
    .sort((a, b) => a.rank - b.rank || a.entry.name.length - b.entry.name.length)

  return ranked.slice(0, MAX_SUGGESTIONS).map(({ entry }) => entry)
}

function resolveShortcode(name, customEmojis = []) {
  const custom = customEmojis.find(emoji => bareName(emoji.shortcode) === name)
  if(custom) return { url: custom.url }

  const unicode = unicodeByName.get(name)
  return unicode ? { native: unicode.native } : null
}

function rankEntry(entry, needle) {
  if(entry.name === needle) return 0
  if(entry.name.startsWith(needle)) return 1
  if(entry.name.includes(needle)) return 2
  if(entry.keywords.some(keyword => keyword.toLowerCase().startsWith(needle))) return 3
  return null
}

function buildUnicodeEntries() {
  return Object.values(emojiMartData.emojis || {})
    .filter(emoji => emoji.skins?.[0]?.native)
    .map(emoji => ({
      name: emoji.id,
      native: emoji.skins[0].native,
      keywords: emoji.keywords || [],
    }))
}

function bareName(shortcode) {
  return `${shortcode || ""}`.replace(/^:|:$/g, "")
}

function escapeAttribute(value) {
  return `${value}`
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
}

export { emojiShortcodePlugin, searchEmojiShortcodes, resolveShortcode }

import hljs from "highlight.js/lib/core"
import bash from "highlight.js/lib/languages/bash"
import css from "highlight.js/lib/languages/css"
import diff from "highlight.js/lib/languages/diff"
import elixir from "highlight.js/lib/languages/elixir"
import go from "highlight.js/lib/languages/go"
import javascript from "highlight.js/lib/languages/javascript"
import json from "highlight.js/lib/languages/json"
import python from "highlight.js/lib/languages/python"
import rust from "highlight.js/lib/languages/rust"
import sql from "highlight.js/lib/languages/sql"
import typescript from "highlight.js/lib/languages/typescript"
import xml from "highlight.js/lib/languages/xml"
import yaml from "highlight.js/lib/languages/yaml"

// Only the curated set is registered. The full highlight.js bundle auto-detects languages in
// untagged blocks, and bot output is untagged plain text that must stay plain.
const LANGUAGES = { bash, css, diff, elixir, go, javascript, json, python, rust, sql, typescript, xml, yaml }
Object.entries(LANGUAGES).forEach(([name, grammar]) => hljs.registerLanguage(name, grammar))
hljs.registerAliases("shell", { languageName: "bash" })

// Returns highlighted HTML for a language the set knows, or null so the caller escapes the code.
// Unknown and missing languages return null: the block must not be guessed at.
export function highlightCode(code, language) {
  if(!language || !hljs.getLanguage(language)) return null
  return hljs.highlight(code, { language, ignoreIllegals: true }).value
}

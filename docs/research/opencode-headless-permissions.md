# How opencode reports permission asks and questions to a headless run

Task: ts-c5db25, for barkeep (ts-3f39d2). Researched 2026-11-18.

- Binary: `opencode v0.0.0-model-rates-202611181850` (a v2 build; source checkout `~/sources/opencode` at `cbc36e5826`).
- Source paths below are relative to `~/sources/opencode/packages`.
- Experiments ran with `opencode run --standalone` in a scratch directory, a throwaway config (`XDG_*` and `OPENCODE_CONFIG*` pointed at scratch), and `openrouter/openai/gpt-oss-20b`. The user's `~/.config/opencode`, service and sessions were not used.

## Answers (BLUF)

| # | Question | Answer |
|---|----------|--------|
| 1 | `run` on an "ask" | `run` answers the ask itself, at once. Without `--auto` it rejects (the tool call fails and the model continues). With `--auto` it approves once. A "deny" rule is never asked and never approved: `--auto` does not override it. |
| 2 | Can another process answer? | Yes over HTTP, but not against `opencode run`: `run` replies first. A client that drives the session over the API (not `run`) sees `permission.asked` and `form.created` on `GET /api/event` and answers by `POST`. |
| 3 | A question tool? | Yes: `question` (options, `multiple`, and free text always allowed). In `run` it is cancelled at once and the model is told to assume. Over the API it creates a pending "form" that is answered with one `POST`, free text included. |
| 4 | Per-agent permissions | Yes. `agent.<name>.permission` in `opencode.json[c]` (or `agent/<name>.md` front matter). `OPENCODE_CONFIG=<file>` selects a file without touching `~/.config/opencode`, but the global config still merges (see 4). |
| 5 | Plugin | Yes, and it is the simplest bridge: a `permission.hook("evaluate")` hook can await an outside decision and set `allow` or `deny`. There is no hook for questions; replace the question tool instead. |
| 6 | Output and files | `--format json` prints one JSON object per line; the answer is the `text` events. `--file` attaches a file by reference. |

Recommendation: see "Recommendation for barkeep" below.

## 1. What `opencode run` does on an "ask"

**Source.** `cli/src/run/noninteractive.ts:97-112`: on every `permission.asked` event for the run's own session (and its subagents), `replyPermission` posts a reply at once. `decision` is `"once"` if `--auto`, else `"reject"` with the message "This non-interactive run cannot ask the user for permission, so the request was rejected. Continue without this action." (line 57). Without `--auto` it also prints `! permission requested: ... auto-rejecting`. `--auto` is declared at `cli/src/commands/commands.ts:38` ("Auto-approve permissions that are not explicitly denied").

**Experiments** (bash rule `"*": "ask"`, `"rm *": "deny"`):

| Case | Command | Observed |
|------|---------|----------|
| Ask, no `--auto` | `opencode run --standalone --model M --format json "Run exactly: echo hello-ask"` | stderr/stdout: `permission requested: shell (echo hello-ask); auto-rejecting`; `tool_use` with `state.status:"error"`, `error:"This non-interactive run cannot ask the user for permission, so the request was rejected. ..."`; exit 0; the model said "I can't execute that command". The run took ~15 s and did not wait. |
| Ask, `--auto` | same plus `--auto` | `tool_use` `status:"completed"`; the command ran. |
| Deny, `--auto` | `... --auto ... "Run exactly: rm victim.txt"` | `tool_use` `status:"error"`, `error:"Permission denied: shell"`. `victim.txt` still existed afterwards. |

So: wait = no, deny = yes (without `--auto`), print = a warning line, exit code stays 0. `--auto` approves only what the rules leave as "ask". A deny rule wins.

Consequence: with `run`, "ask" is not a state a human can answer. It is "reject" or "allow".

## 2. Can another process answer the ask?

**Service and API.** `opencode serve` starts the HTTP server (`--port`, `--hostname`). The background service is the same server (`serve --service`). Auth is HTTP Basic, user `opencode`, password from `OPENCODE_SERVER_PASSWORD` (service: the `password` in `~/.config/opencode/service.json`; do not copy it into docs or logs). Schema: `protocol/openapi.json`.

Endpoints I used against `opencode serve --port 47311`:

- `POST /api/session` body `{"title":"...","model":{"providerID","id"},"agent":"barkeep","permissions":[...]}` creates a session. The `location` is the server's cwd unless the request sends the `x-opencode-directory` header (URL-encoded) or `?location[directory]=` (`server/src/location.ts:60`).
- `POST /api/session/{id}/prompt` body `{"text","files":[...],"delivery"}` starts a turn.
- `GET /api/event` is an SSE stream. Each frame is `data: {"id","created","type","location","data"}`. Event `permission.asked` carries `data = {id:"per_...", sessionID, action:"shell", resources:["echo hello-api"], save:["echo *"], source:{type:"tool",messageID,id}}`. `permission.replied` follows the answer.
- `GET /api/session/{id}/permission` lists pending asks.
- `POST /api/session/{id}/permission/{requestID}/reply` body `{"decision":"once"|"always"|"reject","message":"..."}` returns 204. Observed: after `once`, the tool ran, `permission.replied` fired and the turn finished. Without any reply the turn stayed paused (nothing timed out in the 10 s I watched).
- `GET /api/session?search=<text>` finds sessions by title.
- `"always"` saves the rule shown in `save` (here `echo *`).

**The race with `run`.** `run` subscribes to the same stream and replies to its own session's asks at once (lines 153-155 and the sweep at 225-233). A second process cannot reliably answer first. The answer in both cases is therefore: do not use `run` as the driver if a human-style answer is wanted; drive the session over the API (client library `@opencode/client`, `packages/client`) or decide inside a plugin (section 5).

**Finding the session an `opencode run` made.**

- `--title "barkeep:post-17:msg-3"` (verified: `GET /api/session?search=barkeep:post-17` returned the session with that title).
- The first event line of `--format json` already carries `sessionID` (`step_start`), so the parent can read it from stdout.
- `--session <id>` "continue, or create if it does not exist" (help text) lets barkeep choose the id.
- `--archived` keeps scripted sessions out of the user's lists (verified: the session listed `time.archived`).

**Shared service vs `--standalone`.** Without `--standalone`, `run` talks to the user's background service. `OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR` and `OPENCODE_SERVER_PASSWORD` are read by the server process when it starts (`cli/src/server-process.ts:122-133`), so a client's env does not reach an already running service (source reading; I did not start runs against the user's service). `--standalone` starts a private server per run that reads the env. Cost: one server start per run.

## 3. The question tool

**Tool.** `question` (`core/src/tool/plugin/question.ts`). Input: `questions[]` of `{question, header, options[{label,description}], multiple?}`. The description says "A 'Type your own answer' option is added automatically". It is allowed for the default agent `build` (`core/src/plugin/agent.ts:60`) and denied for subagents (line 69). It first calls `permission.assert("question")`, so an agent permission of `question: deny` removes it.

**It is a "form".** `Form.ask` creates a pending form: `metadata.kind:"question"`, fields `q0, q1...` of type `string` (single) or `multiselect`, `options`, and `custom:true` (free text allowed).

**Headless `run`.** `run` cancels it on `form.created` (`noninteractive.ts:114-139`). Observed in a deny test: the model called `question` and got `tool_use` `state.error: "This non-interactive run cannot ask the user questions, so the question was cancelled. Continue without an answer; make reasonable assumptions and state them."`. The run did not fail.

**Over the API** (observed). Event `form.created` with `data.form = {id:"frm_...", sessionID, title:"Questions", metadata:{kind:"question",tool:{messageID,id}}, fields:[{key:"q0", title:"Color preference", description:"Which color do you prefer?", type:"string", options:[{value:"Red",label:"Red",description:"..."},...], custom:true}]}`. `GET /api/session/{id}/form` lists pending forms. Answer: `POST /api/session/{id}/form/{formID}/reply` body `{"answer":{"q0":"chartreuse (free text)"}}` returns 204; `form.replied` fires. The model received `User has answered your questions: "Which color do you prefer?"="chartreuse (free text)"` and replied "You chose: chartreuse". For `multiselect` the value is an array of strings. `POST .../form/{formID}/cancel` with a `message` makes the model continue with that message as feedback (as `run` does).

## 4. Per-agent permission config

**Where.** `opencode.json` or `opencode.jsonc`, key `agent.<name>` (`mode`, `description`, `prompt`, `model`, `permission`), or a markdown file `agent/<name>.md` / `agents/<name>.md` with front matter (`core/src/config/plugin/agent.ts:27`). Select it with `opencode run --agent barkeep`.

**Rules.** Permission is `action -> "allow"|"ask"|"deny"` or `action -> {pattern: effect}`. Patterns are globs matched on the resource, and the last matching rule wins, so key order is policy (`core/src/v1/config/permission.ts:7-10`). `question`, `websearch`, `doom_loop` take only a plain effect (line 24). For bash the action is `shell` in events but `bash` in config (observed: config key `bash` governed the `shell` tool).

**Experiment** (config file `repo/opencode.jsonc`, agent `barkeep`, `bash: {"*":"ask","echo *":"allow","git status*":"allow","rm *":"deny"}`, `edit:"deny"`, `question:"allow"`), run with `--auto --agent barkeep`:

| Command | Result |
|---------|--------|
| `echo hello-allow` | completed |
| `touch made.txt` | completed (the "ask" was auto-approved by `--auto`; `made.txt` exists) |
| `rm victim.txt` | `Permission denied: shell`; file kept |

**Using a config from barkeep's repo without touching `~/.config/opencode`:**

- `OPENCODE_CONFIG=/path/to/barkeep/opencode.jsonc` loads one explicit file (worked).
- `OPENCODE_CONFIG_DIR=/path/to/barkeep/opencode` adds a config directory (agents, plugins; worked for the plugin below).
- `OPENCODE_CONFIG_CONTENT='{...}'` passes JSON inline.
- `OPENCODE_DISABLE_PROJECT_CONFIG=1` ignores `opencode.json`/`.opencode` in the work directory, which matters when a run's cwd is `~/build/<project>`.
- Limit: the global config (`~/.config/opencode`, and `/etc/opencode`) is still merged (`core/src/config/discovery.ts:62-70,128-133`). Nothing I found turns it off from the CLI. To fully isolate, set `XDG_CONFIG_HOME` to a barkeep-owned directory, as the experiments did; the cost is that provider credentials in `XDG_DATA_HOME` (`auth.json`) and the model catalog cache (`XDG_CACHE_HOME`) must come along or be left in place (set only `XDG_CONFIG_HOME`).
- These env vars take effect only with `--standalone` (section 2).
- Caveat: because the global config merges, a user rule can loosen or tighten barkeep's agent. Put the deny list in the agent's own `permission`, and verify the effective result.

## 5. Plugins

**API.** v2 plugins are files in a `plugins/` (or `plugin/`) directory of a config directory (`core/src/plugin/source-directory.ts:7`). `~/.config/opencode/plugins/prog.ts` is the user's v2 example (`Plugin.define({id, setup(ctx)})`, `ctx.session.hook("context", ...)`). `herdr-agent-state.js` and `amux-agent-state.js` listen for the old event names (`permission.asked`, `question.asked`) to show a "blocked" state; they only watch and do not answer. I did not check whether they still fire on this build.

**Permission hook.** `ctx.permission.hook("evaluate", cb)` (`plugin/src/promise/permission.ts`). `cb` gets `{sessionID, agent, action, resources, metadata, source, effect, message}` and may be async; it may set `effect` to `allow`, `deny` or `ask`, and `message`. Experiment (`repo/plugins/gate.ts`, loaded through `OPENCODE_CONFIG_DIR`, run **without** `--auto`):

- The hook fired for every evaluation, including ones the rules already allow (`effect:"allow"`), so it sees all tool calls.
- For an `ask`, the hook awaited 3 s (a stand-in for a poll) and then set `deny`. The tool call failed with `error:"decided by gate plugin"` and no `permission.asked` event was raised, so `run` never auto-rejected.
- `ctx.permission.assert` is also available, and `ctx.tool` can register tools.

**Questions.** There is no hook for `form.created`. Options: deny the built-in `question` (`question: "deny"`) and register a replacement tool, or give the agent a `tavern ask` command (section "Recommendation").

**Compared with the HTTP API.** A plugin runs inside the opencode process, so there is no event stream, no race with `run`, no session lookup, and it works with plain `opencode run --standalone`. It needs a runtime channel back to barkeep (the plugin can call the `tavern` CLI, or an HTTP endpoint barkeep serves). The API route needs barkeep to be the session driver (it replaces `opencode run`), a second client to maintain, and its own prompt-and-stream code. Plugin API stability: this is a pre-release v2 build; the hook shape may change.

## 6. Final answer text and attachments

**`--format json`** prints JSON Lines on stdout, all with `type`, `timestamp`, `sessionID`:

- `step_start` / `step_finish` (`part.reason`: `tool-calls` or `stop`; `part.cost`, `part.tokens`).
- `tool_use`: `part.tool` (`shell`, `read`, `question`...), `part.state` `{status:"completed"|"error", input, output|error, time}`.
- `text`: `part.text` (a complete text part with `time.start/end`; the observed answer came as a single event).
- `retry`: `{attempt, nextRetryAt, error:{type:"provider.rate-limit",...}}`.
- `error`: `{error:{type:"provider.auth"|"provider.no-route",message,status}}`; exit code 1 (observed) while a rejected tool still exits 0.

Final answer = the `text` parts after the last `tool_use`, or the `text` events of the last `step_finish` with `reason:"stop"`, joined. Check `error` events and the exit code first. (Thinking blocks appear only with `--thinking`.)

**`--file <path>`** (I tested one file): `run --file note.txt "What is the secret word?"` answered `PINEAPPLE-42`. The model got the file by reference and read it with the `read` tool (`input:{path:"note.txt"}`), so the file must be readable at that path from the run's cwd. I did not test images or several files.

## Recommendation for barkeep

Use the plugin for permissions and a `tavern` command (or the MCP tool) for questions. Do not build an HTTP client first.

1. **Run** `opencode run --standalone --agent barkeep --format json --title "barkeep:<post>:<msg>" --archived [--file ...]` with `OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR` and `OPENCODE_DISABLE_PROJECT_CONFIG=1` from barkeep's repo. No `--auto`.
2. **Permissions: a `permission.evaluate` plugin** in barkeep's config directory. Rules in the `barkeep` agent decide the obvious cases: `allow` for safe patterns, `deny` for destructive ones (denies are never asked). For `ask`, the plugin calls barkeep (the `tavern` client) to create the poll (restricted to the allowlist, closes after 1 vote), awaits the result, then sets `effect` to `allow` or `deny` with a `message`. Map poll options to allow / deny; "always" has no equivalent here (it would be a barkeep-side rule, so leave it out). Add a timeout in the plugin so an unanswered poll becomes `deny`, because the run would otherwise wait with no one watching (the hook has no built-in timeout; I did not test a very long await).
3. **Questions:** set `question: "deny"` on the agent and give the agent a `tavern ask` command (post a poll, block until closed, print the answer; Other text comes back as free text). This is the same channel as the planned `tavern` CLI/MCP, so it needs no opencode internals. If the built-in `question` tool must be used, the plugin can register a tool with the same name and the same input schema.
4. **Final text:** parse `text` events; if no `tavern post` happened, post that text.
5. **Stop:** kill the process. Nothing else is needed since the session is private to the run.

**Costs and risks**

- The plugin API is unstable pre-release code (`v0.0.0-model-rates-...`); pin a version and add one smoke test that runs the gate against a fake model or a cheap one.
- `--standalone` restarts a server per run (~1 s) and does not use the user's warm service; the shared service cannot take per-run env.
- The global `~/.config/opencode` still merges; barkeep's deny list must live in the agent and be checked, or `XDG_CONFIG_HOME` must be isolated (which means supplying credentials).
- A plugin that crashes or hangs can leave an `ask` pending. Wrap the hook in try/catch that sets `deny`.
- The API route (barkeep drives sessions through `@opencode/client`: `permission.asked`, `form.created`, replies) is more general and can offer "always", but it replaces `opencode run`, so barkeep must reimplement prompt delivery, the event loop and the final-text read. Choose it only if the plugin hook proves too restrictive.
- Agent-written tests gather in pure helpers; the plugin and the `tavern ask` blocking call are I/O code and need an integration test with a stub Tavern endpoint.

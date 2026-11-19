# What barkeep should borrow from bb's agent providers

Task: ts-d3d1d7. Source read: `~/sources/bb` (read-only, unmodified). Experiments ran against `opencode v0.0.0-model-rates-202611181850` in a scratch directory with `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME` and `XDG_STATE_HOME` set to scratch paths and model `openrouter/google/gemini-4-neon` (the config default there). The user's `~/.config/opencode` and sessions were not used. The scratch directory is deleted.

## Recommendation

**Keep the hooks + MCP plan. Do not switch to ACP. Borrow three things from bb: the ACP permission and question shape as the model for `barkeep approve` and `tavern_ask`, a per-host concurrency limit, and a typed event/lifecycle record.** ACP stays an optional second launch mode, not the base.

Reasons:

1. **ACP works for opencode and is agent-neutral, but it removes the terminal.** `opencode acp` is a stdio subprocess. The user's decision is that barkeep requires hc (status, `hc attach`, interrupt, kill, `--on`). An ACP session has none of these unless the ACP process itself runs inside an hc terminal, where the user sees JSON-RPC lines, not a TUI. I did not test that.
2. **bb gives no evidence that Claude Code can be driven through a blocking hook.** bb answers Claude Code permission asks inside its own process with the SDK's `canUseTool` callback. Its `PermissionRequest` hook only records the tool use and returns `{continue: true}`. The open risk in ts-3f39d2 (can a Claude Code `PermissionRequest` hook block for minutes) is still open. bb does not run Claude Code through ACP either.
3. **ACP's real value is one wire shape for asks.** I verified it for opencode (below). Barkeep can copy that shape (options with kinds, a form schema with an "other" field) for its own poll messages, so one code path serves every agent.

Costs of the recommendation: per-agent work stays (a permission hook, a question-tool disable, an answer reader; see section 4). The opencode plugin API is pre-release. The hold-for-minutes risk for Claude Code needs its own test before the build.

Cost of the alternative (ACP only): lose hc takeover and hc status; barkeep becomes the session host (it must supervise child processes, restart them, and keep sessions alive between messages). That is bb's whole bridge layer rebuilt.

A mix is possible and cheap to add later: a launch template with `mode = "acp"` that spawns `opencode acp` as a child of barkeep, for hosts without hc or for agents with no hook. Not needed for the first build.

## 1. How bb's provider layer is shaped

**Registration.** A provider is a plugin that calls `bb.providers.register({id, displayName, capabilities, deriveProviderOptions, ...})` (`docs/provider-plugin-api.md:46-95`). Capability flags declared before any session starts (`provider-plugin-api.md:64-75`): `permissionModes`, `fork` (`"none" | "tip" | "checkpoint"`), `supportsNativeUserQuestion`, `supportsManualCompaction`, `supportsThreadArchive`, `supportsThreadRename`, `supportsServiceTier`, `reasoningLevels`.

**Bridge.** The plugin ships a bridge process (`experimental_defineProviderBridge({handleLine, start, onClose})`, `provider-plugin-api.md:228-232`). It runs on the host that holds the agent, one process per provider, and speaks JSON-RPC over stdio to bb's daemon (`docs/provider-bridge-protocol.md:32`).

**Handshake** (reported at `initialize`, `provider-plugin-api.md:241-255`): `sessionRestore`, `threadArchive`, `threadRename`, `threadGoalClear`, `fork`, `approvalEnforcedBy: "runtime" | "provider"`, `steerMode`, `skills.configure`, `grammarVersions`.

**Commands runtime → bridge** (`provider-plugin-api.md:257-262`): `initialize`, `model/list`, `thread/{start,resume,fork,stop,discard,archive,unarchive,name/set,goal/clear}`, `turn/{start,steer}`, `skills/configure`, `provider/{health,usage,installation/*}`.

**Output bridge → runtime** (`provider-plugin-api.md:274-278`): notifications `thread/delta` (one streaming grammar of items, turns and usage), `thread/identity`, `session/replaced`, `provider/recovery`, `provider/raw`, `error`; request channels `item/tool/call` and `interaction/request`.

**Lifecycle.**
- Start: `thread/start` returns `{providerThreadId, sessionRestorable?}` (`provider-bridge-protocol.md:548-551`). A turn is `turn/start`; every accepted turn ends in exactly one terminal event (`:457`).
- Stream: `thread/delta` items with open, settle, and boundary events; the host drops grammar violations with a warning (`:535-544`).
- Stop: `thread/stop` with `intent: interrupt` (settles the turn as interrupted) or `release` (detaches an idle session); afterwards the bridge holds nothing for the thread (`:490-500`). In the ACP bridge, interrupt sends the `session/cancel` notification (`packages/provider-bridge-acp/src/bridge/bridge.ts:2697`, `:3026`).
- Fork: `thread/fork`; absent checkpoint id means fork at the tip; a `"tip"` provider rejects checkpoint forks (`:564-566`). ACP forks use `session/fork` when the agent advertises it (`bridge.ts:2449`, `:2491`).
- Recovery is typed (`sessionArchived | authRequired | restartRecommended | staleTurn | rateLimited`), never matched on error text (`provider-plugin-api.md`, "provider/recovery" block).

**What one provider must implement:** the bridge commands above, the delta translation to bb's vocabulary (message, command, fileChange, tool, ...), a presentation (label, glyph, detail) for every tool row, and a `model/list`. Principle 1 says first-party providers use only this public API (`provider-plugin-api.md:18-19`).

## 2. How bb answers permission asks and agent questions

Central rule: `approvalEnforcedBy` says who enforces the permission mode. Claude Code reports `"provider"` (`plugins/provider-claude-code/src/bridge/bridge.ts:2296`); Codex, Pi and ACP report `"runtime"` (`provider-codex/src/bridge/bridge.ts:1601`, `provider-pi/src/bridge/bridge.ts:520`, `provider-bridge-acp/src/bridge/bridge.ts:3837`). With `"runtime"`, bb auto-decides approvals by mode (`accept-edits` approves file changes, `auto` adds commands and tool use, `full` approves all; `provider-plugin-api.md`, section 4, "Approvals"; check at `packages/agent-runtime/src/runtime-provider-requests.ts:292`).

**Claude Code: the SDK, not hooks.**
- bb runs Claude Code through `@anthropic-ai/claude-agent-sdk` (`bridge.ts:42`, `sdk-session.ts:14`).
- Permissions: `sessionOptions.canUseTool = createCanUseTool(threadIdRef)` (`bridge.ts:2419`). The callback returns a Promise; bb parks it in `pendingInteractiveRequests`, raises `interaction/request`, and resolves the Promise when the user answers or the SDK's abort signal fires (`bridge.ts:1975-2030`). No timeout in this code path.
- Questions: the same callback sees `toolName === "AskUserQuestion"` and forwards it as a bb question card (`bridge.ts:2140-2175`). So `supportsNativeUserQuestion: true` (`provider-claude-code/server.ts:89`).
- Hooks exist only for tracking: `PermissionRequest`, `PreToolUse`, `PostToolUse`, `SubagentStart` and others, each returning `{continue: true}` (`bridge.ts:1313-1448`).
- Extra tools reach the agent through an in-process MCP server built from bb's "dynamic tools" (`tool-proxy-mcp.ts`, `bridge.ts:2422-2430`).

**Questions for agents with no native question tool.** The `ask-user-question` plugin adds a tool named `AskUserQuestion` to providers whose `supportsNativeUserQuestion` is false (`plugins/ask-user-question/src/server.ts:17`, `:132-140`). It shows a card with 2-4 options per question, up to 10 questions, an "Other" field, and a 30-minute default expiry (`PLUGIN_OVERVIEW.md`). This is the same idea as barkeep's `tavern_ask`.

**ACP agents.** `supportsNativeUserQuestion: false` (`plugins/provider-acp/src/declaration.ts:10`); the bridge handles two agent-to-client requests: `session/request_permission` (`bridge.ts:3508`) and `elicitation/create` (`bridge.ts:3517`); see section 3.

**Codex.** Talks to `codex app-server` (`provider-codex/src/bridge/app-server-connection.ts`) and has its own `interactive-requests.ts` and `async-questions.ts`. I did not read these in detail.

## 3. ACP

**Agents bb runs through ACP** (`plugins/provider-acp/src/known-agents.ts`): Cursor (`cursor-agent acp`, `:61`), opencode (`opencode acp`, `:102`), omp (`omp acp`, `:128`), Grok (`grok agent stdio`, `:163`, with `permissionCli: {full: ["--always-approve"]}`), Hermes (`hermes acp`, `:191`). Users can add custom agents with a command, args, env (`agents.ts` `customAcpAgentSchema`). Claude Code and Codex are not ACP in bb.

**ACP shape for asks** (bb client code plus my experiments):
- Permission: agent sends the request `session/request_permission` with `toolCall` (`toolCallId`, `title`, `kind`, `rawInput`, `locations`) and `options[]` (`optionId`, `kind` = `allow_once | allow_always | reject_once`, `name`). The client replies `{outcome: {outcome: "selected", optionId}}` or `{outcome: {outcome: "cancelled"}}` (`bridge.ts:1975-2060`).
- Question: agent sends `elicitation/create` with a JSON-schema form (`requestedSchema.properties`); client replies `{action: "accept", content}`, `{action: "decline"}` or `{action: "cancel"}` (`elicitation.ts:9-12`). The client must declare the `elicitation` capability at `initialize` (bb: `bridge.ts:2436`; opencode reads `client.elicitation.form`, `~/sources/opencode/packages/cli/src/acp/capabilities.ts:9-13`).

**Experiment: does `opencode acp` deliver permission requests and wait?** Yes.

Setup: a 40-line Bun client (`client.mjs`, scratch, deleted) spawned `opencode acp`, sent `initialize` (`protocolVersion: 1`), `session/new`, `session/prompt`, and answered agent requests. Config: `{"permission":{"bash":"ask","edit":"ask"}}`.

Run 1, prompt "Run exactly this shell command and report its output: echo hello-acp", client answer delayed 6 s:
```
6.2s AGENT->CLIENT REQUEST session/request_permission {"sessionId":"ses_e0df…","toolCall":{"toolCallId":"call_…","name":"shell","title":"echo hello-acp","kind":"execute","status":"pending","locations":[…],"rawInput":{"command":"echo hello-acp","cwd":"…/work"}},"options":[{"optionId":"once","kind":"allow_once","name":"Allow once"},{"optionId":"always","kind":"allow_always","name":"Always allow"},{"optionId":"reject","kind":"reject_once","name":"Reject"}]}
12.2s CLIENT ANSWERS after 6s delay once
12.5s NOTIFY … tool_call_update [{"type":"content","content":{"type":"text","text":"hello-acp\n"}}]
14.2s NOTIFY … agent_message_chunk {"type":"text","text":"Output:\n\n```\nhello-acp\n```"}
14.2s PROMPT DONE {"stopReason":"end_turn","usage":{…}}
```
The agent waited, the command ran only after the answer, and the final text arrived as `agent_message_chunk` notifications. This differs from `opencode run`, which auto-rejects asks at once (see `opencode-headless-permissions.md`).

Run 3, same prompt, answer delayed 100 s: ask at 4.6 s, answer at 104.6 s, `PROMPT DONE` at 106.6 s. A 100-second hold works (the hold-for-minutes risk is not an obstacle for opencode ACP; longer was not tested).

Run 2, question, with `clientCapabilities.elicitation.form = {}`:
```
6.1s AGENT->CLIENT REQUEST elicitation/create {"mode":"form","sessionId":"ses_…","toolCallId":"call_…","message":"Questions","requestedSchema":{"type":"object","properties":{"q0":{"type":"string","title":"Color preference","description":"Which color do you prefer?","oneOf":[{"const":"Red",…},{"const":"Blue",…}]},"q0_custom":{"type":"string","title":"Color preference (other)","description":"Type your own answer"}},"required":[]}}
9.1s CLIENT ELICIT ANSWER q0   (answered {"q0":"chartreuse"} after 3 s)
12.3s NOTIFY … agent_message_chunk "You answered: **chartreuse**."
```
Options and a free-text "other" field come in one schema; the answer went back to the model.

Other facts from `initialize` (run 1): `agentCapabilities.loadSession: true`, `sessionCapabilities` lists `close, delete, fork, list, resume`, `promptCapabilities` accepts image and embedded context, `authMethods` has `opencode-login`. `session/set_model` returns "Method not found": the model is a `configOptions` entry returned by `session/new` (`currentValue`, `options[]`), so model choice goes through the generic config-option call (bb: `bridge.ts:2868`, `session/set_mode` and dialect code in `dialect.ts`).

Not tested: images, several concurrent sessions in one `opencode acp` process, `session/fork`, `session/resume`, killing the client mid-ask.

## 4. Comparison with barkeep's current plan

| | hooks + MCP in an hc terminal (current plan) | ACP (stdio subprocess) |
|---|---|---|
| Per-agent integration points | 4: launch template; a permission hook (opencode plugin, Claude Code `PermissionRequest` hook); a switch to turn off the agent's own question tool; a reader for the last answer text. `tavern_ask` MCP and `barkeep approve` are shared. | 1: command and args (`known-agents.ts`). Permission, question, text stream, cancel, resume are the protocol. bb still needs a per-agent "dialect" for quirks (`dialect` fields in `known-agents.ts`; `permissionCli` for Grok at `:166`). |
| User takes over a live session (`hc attach`) | Yes: it is a terminal. | No. No terminal exists. |
| Stop | `hc interrupt` / `hc kill`. | `session/cancel` notification, then kill the child. |
| Reading the final reply | Per-agent (agent's own transcript or print mode). | `agent_message_chunk` notifications and `stopReason` on `session/prompt`. |
| Fragility | Opencode plugin API is pre-release; Claude Code hook-block duration untested; two config switches per agent drift with versions. | Pre-1.0 protocol, agents implement parts differently (bb carries dialect code); I saw `session/set_model` missing on opencode; requires barkeep to supervise the child. |
| Status, `--on` | hc | Barkeep must build both. |

**What ACP costs against "barkeep requires hc".** The ACP process holds the conversation in memory and on stdio; nothing for hc to attach to. Both at once is only partly possible:
- *Later takeover:* opencode keeps ACP sessions in its own store and advertises `resume`, `list` and `fork`; its CLI takes a `--session` flag (`~/sources/opencode/packages/cli/src/commands/handlers/default.ts:53`). So after the ACP turn ends, a user could probably open the same session in the opencode TUI. I did not run the TUI, and takeover during a live turn is not possible.
- *ACP inside hc:* run `opencode acp` as the command of an hc terminal and let barkeep speak to it through hc's input and output. This gives hc status, kill and `--on`, but `hc attach` shows protocol lines, and barkeep would need to read stdout from hc. Untested.

## 5. Other bb ideas worth borrowing

| Idea | Where | Value | Cost |
|---|---|---|---|
| Per-host concurrency limit: a new turn waits in line when running threads meet the limit (default one per CPU), rechecked when a thread goes idle, fails or is archived | `plugins/concurrency-limit/PLUGIN_OVERVIEW.md` | Stops a busy forum from launching dozens of agents; fits barkeep's per-post queue | Small: a counter and a queue in barkeep |
| One lifecycle record per interaction (id, status, origin, ask, answer) | `provider-plugin-api.md`, section 4, "Every status change" | An audit trail of who approved what, the thing the allowlist guardrail wants | Small: one table or log line per poll |
| Approval subject kinds: `command`, `file_change`, `tool_use`, `permission_grant`; a mode (`accept-edits`, `auto`, `full`) that auto-decides the low-risk ones | `provider-plugin-api.md`, section 4, "Approvals" | Fewer polls: auto-approve reads and edits, ask only for commands | Medium: classify each agent's tool names; ACP's `kind` (`execute`, `edit`, ...) makes it easy there |
| Question card limits and expiry (2-4 options, 10 questions, "Other", 30 min default) | `plugins/ask-user-question/PLUGIN_OVERVIEW.md` | A tested bound for `tavern_ask`; a timeout that ends a stuck ask | Small |
| Typed recovery (`authRequired`, `rateLimited`, ...) not text matching | `provider-plugin-api.md`, "provider/recovery" block | Barkeep can post "sign in on host X" instead of a stack trace | Medium: needs each agent's error shapes |
| Watchdog: a turn with no start event within a bound becomes a visible event | `provider-bridge-protocol.md`, "Turn lifecycle" item 4 | A hung session shows in the forum post | Small |
| Fork: tip fork of a session | `provider-bridge-protocol.md:564-566` | A reply thread could branch from a past message | Large for terminal agents (needs each agent's fork); not worth it in v1 |
| Automations: cron or one-shot start of an agent thread with a prompt, run history | `plugins/automations/PLUGIN_OVERVIEW.md` | "Run this post's prompt every morning" | Medium; later feature, outside the current task |
| Event model: one streaming grammar (`thread/delta`) for every agent | `provider-bridge-protocol.md`, "The timeline lane" | Only relevant if barkeep goes ACP | Large; skip |

## Open items for the build

- Test a Claude Code `PermissionRequest` hook that blocks for minutes (still open from ts-3f39d2). bb's own approach does not answer it: it uses an in-process SDK callback.
- Decide whether barkeep wants an optional `mode = "acp"` launch template. I recommend not in v1.

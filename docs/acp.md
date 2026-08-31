# ACP usage

fx exposes a native Agent Client Protocol server over standard input and standard output:

```bash
fx acp
```

The transport is newline-delimited JSON-RPC 2.0. A client initializes the connection, creates or loads a session, and sends prompts with the standard ACP methods.

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
{"jsonrpc":"2.0","id":2,"method":"session/new","params":{}}
{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"SESSION_ID","prompt":[{"type":"text","text":"Run the focused tests"}]}}
```

## fx extension discovery

The initialize response advertises fx-specific capabilities under `_meta.fx`:

```json
{
  "_meta": {
    "fx": {
      "turnSteer": true,
      "turnStatus": true,
      "backgroundTerminals": true,
      "processStatusCommand": "/ps",
      "unifiedExec": {"writeStdin": true, "kill": true},
      "providerControl": {"switch": true, "login": true, "setup": true, "configureByok": true, "usage": true}
    }
  }
}
```

These fields and the methods below are fx extensions, not standard ACP methods. Clients should check the advertised metadata before using them.

The design follows the same separation used by Codex app-server: starting a new turn and steering an active turn are different operations, and background terminal state has a separate control-plane query.

## Provider control

Native ACP can initialize before a model credential is available. This lets an
ACP client complete login or configure a BYOK endpoint over the protocol before
creating its first session. A prompt still requires a working credential.

Switch the process or active session to a saved provider credential with:

```json
{"jsonrpc":"2.0","id":20,"method":"fx/provider/switch","params":{"provider":"codex"}}
```

`provider` is `gateway`, `codex`, or `grok`. `sessionId` is optional; when it is
present it must identify the active session. The response is written after the
credential and model catalog have been validated:

```json
{"jsonrpc":"2.0","id":20,"result":{"provider":"codex","model":"gpt-5.6-sol"}}
```

The standard `session/set_config_option` provider option uses the same
background activation path. While catalog loading is in progress, the ACP read
loop remains available for cancellation, turn status, background-terminal
queries, provider-login status, and Unified Exec writes or termination. Other
state-changing requests receive `Provider operation already in progress`.

### Provider setup

Import compatible logins already owned by Codex CLI and Grok Build without
opening another browser authorization flow:

```json
{"jsonrpc":"2.0","id":18,"method":"fx/provider/setup/start","params":{}}
```

The start response is immediate. Poll the background import through:

```json
{"jsonrpc":"2.0","id":19,"method":"fx/provider/setup/status","params":{}}
```

The terminal response has `state: "completed"` and a credential-free report
for `codex` and `grok`. Each status is `imported`, `already_configured`,
`not_found`, `incompatible`, `invalid`, or `unavailable`. The importer reads
`CODEX_HOME/auth.json` or `~/.codex/auth.json`, and `GROK_HOME/auth.json` or
`~/.grok/auth.json`. It never changes those source files or replaces an
existing fx login. Call `fx/provider/switch` afterward when the imported
provider should become active; setup never changes provider selection.

### Provider login

Start browser login for Codex or Grok:

```json
{"jsonrpc":"2.0","id":21,"method":"fx/provider/login/start","params":{"provider":"codex"}}
```

The `provider` field is optional. When omitted, fx detects a valid stored
subscription session without network I/O, preferring Codex and falling back to
Grok. Explicit provider values remain strict and never cross-send credentials.

The result contains `state`, `authorizationUrl`, and `acceptsManualCode`. Open
the authorization URL in the user's browser, then query completion without
blocking the ACP connection:

```json
{"jsonrpc":"2.0","id":22,"method":"fx/provider/login/status","params":{}}
```

Possible states are `idle`, `polling`, `succeeded`, `failed`, and `cancelled`.
Grok login can accept a manually copied authorization code when
`acceptsManualCode` is true:

```json
{"jsonrpc":"2.0","id":23,"method":"fx/provider/login/submitCode","params":{"code":"COPIED_CODE"}}
```

Cancel a pending login with `fx/provider/login/cancel`. A successful login is
saved in the same private profile file used by the native CLI. Use
`fx/provider/switch` afterward to activate its catalog for the process or active
session.

### Connection-scoped BYOK configuration

Configure and validate a Responses-compatible API root and API key directly:

```json
{"jsonrpc":"2.0","id":24,"method":"fx/provider/configure","params":{"baseUrl":"https://gateway.example.com/v1","apiKey":"YOUR_KEY"}}
```

fx derives `/responses` and `/models`, fetches the model catalog with the
provided key, and activates the gateway provider only after validation. Remote
URLs must use HTTPS. Loopback HTTP is allowed only with an explicit port.

```json
{"jsonrpc":"2.0","id":24,"result":{"provider":"gateway","model":"gpt-5","responseUrl":"https://gateway.example.com/v1/responses","credentialPersistence":"connection"}}
```

The API key is never echoed. This ACP method keeps it only in the current fx
process and does not write it to `settings.json` or a session log. Start a new
ACP connection or call the method again to replace it. Use environment or
profile-owned credential configuration when persistence across process restarts
is required. The response URL and key remain one connection-scoped binding when
you temporarily switch to Codex or Grok; switching back to `gateway` restores
both. Ordinary model requests, automatic permission reviews, and manual or
automatic remote compaction all use that same binding. Persistent subagents
also retain the provider and connection route captured for each child turn.
Changing the parent provider does not reroute an existing child, and replacing
the connection binding does not alter a child turn already in progress.

## Compact a session

Send the exact local command `/compact` through `session/prompt`:

```json
{"jsonrpc":"2.0","id":25,"method":"session/prompt","params":{"sessionId":"SESSION_ID","prompt":[{"type":"text","text":"/compact"}]}}
```

ACP uses the same strategy module and session installation path as the TUI and
inline overflow recovery. Eligible Responses routes try native remote
compaction first. Other routes, and rejected or unavailable remote requests,
use the active model to create a structured local replacement. The bounded
deterministic projection is used only when model compaction cannot complete.
The response arrives as an `agent_message_chunk`, followed by the normal
`session/prompt` completion. The installed portable summary and optional opaque
provider checkpoint are persisted together.

## Query the active turn

Use `fx/turn/status` at any time after initialization:

```json
{"jsonrpc":"2.0","id":10,"method":"fx/turn/status","params":{"sessionId":"SESSION_ID"}}
```

While a turn is running, the result includes its stable turn ID:

```json
{
  "sessionId": "SESSION_ID",
  "state": "running",
  "activeTurnId": "turn-42",
  "acceptingSteers": true,
  "pendingSteers": 0,
  "cancelRequested": false
}
```

When no turn is active, `state` is `idle` and `activeTurnId` is `null`.

## Query provider usage

`fx/provider/usage` returns the provider-neutral aggregate used by the TUI
footer. It is safe to call while a turn or provider job is active because it
only snapshots the local session ledger and never performs network I/O:

```json
{"jsonrpc":"2.0","id":7,"method":"fx/provider/usage","params":{}}
```

The `snapshot` object includes provider and credential-source labels, account
identity presence, input/output/total tokens, request count, and context
fields. Remote account limits remain an explicit CLI operation (`fx usage
--codex`) so an ACP control-plane read cannot be held by a slow provider.

## Steer an active turn

Use `fx/turn/steer` to append user input to the currently running regular turn:

```json
{
  "jsonrpc": "2.0",
  "id": 11,
  "method": "fx/turn/steer",
  "params": {
    "sessionId": "SESSION_ID",
    "expectedTurnId": "turn-42",
    "input": [
      {"type":"text","text":"Focus on the failing ACP test first."}
    ]
  }
}
```

A successful request is acknowledged immediately:

```json
{"jsonrpc":"2.0","id":11,"result":{"turnId":"turn-42"}}
```

The input is consumed at the next model-step boundary. It does not interrupt a model response or tool call already in progress. The next model request receives the completed assistant step followed by the additional user input.

`expectedTurnId` prevents a delayed client message from steering a newer turn accidentally. The request fails when the session does not own the active turn, the turn ID is stale, or the turn has stopped accepting input.

Image prompt blocks are supported for native sessions. Send standard ACP base64
content with `data` and `mimeType`; fx verifies the bytes and stores a session
snapshot before sending them to a vision-capable provider. Image blocks are not
accepted by `fx/turn/steer`, which remains text-only.

```json
{"jsonrpc":"2.0","id":14,"method":"session/prompt","params":{"sessionId":"SESSION_ID","prompt":[{"type":"text","text":"Describe this image"},{"type":"image","data":"iVBORw0KGgo...","mimeType":"image/png"}]}}
```

A second standard `session/prompt` request is still treated as a new turn and is rejected while another prompt is active. Use `fx/turn/steer` for same-turn input.

## Inspect running processes with `/ps`

Send the exact local command `/ps` through `session/prompt`:

```json
{"jsonrpc":"2.0","id":12,"method":"session/prompt","params":{"sessionId":"SESSION_ID","prompt":[{"type":"text","text":"/ps"}]}}
```

`/ps` is handled locally and never sent to the model. It works while another turn is running. fx emits an `agent_message_chunk` update containing:

- Whether the agent turn is idle, starting, or running
- The active turn ID
- The number of queued steer messages
- Running durable terminal sessions
- Running legacy background tasks

The request then completes with the normal ACP prompt response:

```json
{"jsonrpc":"2.0","id":12,"result":{"stopReason":"end_turn"}}
```

## List background terminals as structured data

Clients that need structured state should use `fx/backgroundTerminals/list` instead of parsing `/ps` text:

```json
{"jsonrpc":"2.0","id":13,"method":"fx/backgroundTerminals/list","params":{"sessionId":"SESSION_ID"}}
```

Example result:

```json
{
  "data": [
    {
      "kind": "terminal",
      "id": "TERMINAL_SESSION_ID",
      "command": "zig build test",
      "state": "running",
      "backend": "native"
    }
  ],
  "nextCursor": null
}
```

The catalog is refreshed from the durable terminal owner before the response is written. `kind` is `terminal` for durable terminal sessions and `background` for older background-runtime tasks.

## Unified Exec commands

A native writable ACP session advertises `exec_command` and `write_stdin`. `exec_command` waits for a bounded yield window, returns immediately when the command exits, or returns a numeric session ID while the same process continues running. `write_stdin` uses that ID to poll newly available output or send input.

Unified Exec processes are session-local and are not durable terminal catalog entries, so they do not appear in `/ps` or `fx/backgroundTerminals/list`. WASM ACP sessions, read-only sessions, and configurations without native process support do not advertise these tools and do not fall back to the removed model-facing `terminal` tool.

These are the only model-facing shell tools. Internal provider, MCP, search, and
authentication subprocesses remain service implementation details and are not
advertised as alternate command tools.

### Tool-call visualization

fx uses one stable `toolCallId` from admission through completion. The initial
standard ACP `tool_call` notification includes the rendered command title and
validated structured input:

```json
{"sessionUpdate":"tool_call","toolCallId":"CALL_ID","title":"Running zig build","kind":"execute","status":"pending","rawInput":{"cmd":"zig build","workdir":"."}}
```

While the process runs, fx sends `tool_call_update` notifications as stdout and
stderr become available. ACP replaces a tool call's `content`, so each update
contains a bounded accumulated preview rather than only the latest fragment.
`rawOutput` also preserves the current stream and exact new chunk for clients
that render their own incremental command view:

```json
{"sessionUpdate":"tool_call_update","toolCallId":"CALL_ID","status":"in_progress","content":[{"type":"content","content":{"type":"text","text":"compile step 1\ncompile step 2\n"}}],"rawOutput":{"stream":"stdout","chunk":"compile step 2\n","aggregatedOutput":"compile step 1\ncompile step 2\n","truncated":false}}
```

The preview retains at most 64 KiB per active call and sets `truncated` after
discarding older bytes at a UTF-8 boundary. ANSI controls are removed,
multibyte characters split across pipe reads are buffered, and invalid bytes
are rendered as visible `\xNN` text so every notification remains valid JSON.
Pipe readers place owned chunks in a bounded queue; transport writes happen
outside the process-control lock, so client backpressure cannot block polling,
input, or termination. The terminal result update includes standard
`rawOutput` with the rendered output and structured command result. The
top-level `command_result` field remains as an fx compatibility extension for
existing clients.

The terminal lifecycle also replaces the active title, using the same formatter
as the TUI, noninteractive CLI, and child sessions:

```json
{"sessionUpdate":"tool_call_update","toolCallId":"CALL_ID","title":"Ran zig build","status":"completed"}
```

For `write_stdin`, an empty poll transitions from `Waiting for 7` to
`Waited for 7`; a write transitions from `Interacting with 7` to
`Interacted with 7`. A failed command uses its terminal failure summary instead
of leaving an obsolete `Running` title visible.

### Direct Unified Exec interaction

The model-facing `exec_command` result includes a numeric `session_id` whenever
the process remains alive after its yield window. An ACP client can use that ID
to write input or poll output directly while the model turn is still running:

The ID first appears in the normal `session/update` notification for the
completed `exec_command` tool call:

```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"SESSION_ID","update":{"sessionUpdate":"tool_call_update","toolCallId":"CALL_ID","status":"completed","rawOutput":{"output":"Process running with session ID 7","commandResult":{"kind":"foreground","command":"...","cwd":"/workspace","exit_code":null,"signal":null,"timed_out":false,"duration_ms":250,"stdout_bytes":0,"stderr_bytes":0,"truncated":false,"process_id":7}},"command_result":{"kind":"foreground","command":"...","cwd":"/workspace","exit_code":null,"signal":null,"timed_out":false,"duration_ms":250,"stdout_bytes":0,"stderr_bytes":0,"truncated":false,"process_id":7}}}}
```

```json
{"jsonrpc":"2.0","id":15,"method":"fx/unifiedExec/writeStdin","params":{"sessionId":"SESSION_ID","processId":7,"chars":"next input\n"}}
```

The response returns immediately with the output currently available and has
this shape:

```json
{"sessionId":"SESSION_ID","processId":7,"status":"running","output":"...","wallTimeSeconds":0.250,"exitCode":null,"signal":null,"stdoutBytes":12,"stderrBytes":0,"truncated":false}
```

Omit `chars` to take a nonblocking output snapshot. Polling and writing never
hold the ACP dispatch loop open while waiting for process output, so the same
connection can continue to cancel or steer the turn, answer permission
requests, query status, or terminate the process. ACP keeps an independent
output cursor, so these snapshots never consume output awaited by the model.
The legacy `yieldTimeMs`
parameter is accepted and validated for compatibility but does not delay this
ACP method. Terminate the process with:

```json
{"jsonrpc":"2.0","id":16,"method":"fx/unifiedExec/kill","params":{"sessionId":"SESSION_ID","processId":7}}
```

These are fx extensions, not the Codex app-server `process/*` methods: fx keeps
its existing numeric manager IDs and plain-pipe Unified Exec implementation.

## Cancellation

`session/cancel` requests cancellation of the active turn. A Unified Exec process that already yielded remains alive for the ACP session and can be polled in a later turn with `write_stdin`; closing the session cleans up remaining processes. Independently hosted durable terminals keep their existing catalog lifecycle.

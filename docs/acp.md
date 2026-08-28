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
      "processStatusCommand": "/ps"
    }
  }
}
```

These fields and the methods below are fx extensions, not standard ACP methods. Clients should check the advertised metadata before using them.

The design follows the same separation used by Codex app-server: starting a new turn and steering an active turn are different operations, and background terminal state has a separate control-plane query.

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

ACP image prompts are not currently supported, including steer input. Text blocks are supported. Resource blocks retain their embedded text.

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

## Cancellation

`session/cancel` requests cancellation of the active turn. A Unified Exec process that already yielded remains alive for the ACP session and can be polled in a later turn with `write_stdin`; closing the session cleans up remaining processes. Independently hosted durable terminals keep their existing catalog lifecycle.

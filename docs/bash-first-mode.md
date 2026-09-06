# Bash-first workspace mode

FX normally advertises dedicated workspace helpers (`list_files`, `glob_files`,
`grep_files`, and `semantic_search`) alongside the unified shell. Bash-first
mode intentionally removes that overlap from the model-facing tool projection.
The model keeps the unified `exec_command` tool and the normal read/write tools,
and receives one shared instruction to use `rg` for text search and
`rg --files` for file discovery.

This follows the current Codex prompt contract, which prefers `rg` and
`rg --files` because ripgrep is fast and respects repository boundaries. It
also avoids the opposite policy used by Grok Build's dedicated-tool prompt,
where `bash` is explicitly told not to perform file discovery or search. FX
keeps the Grok Build tool implementations available in standard mode while
making shell-first behavior an explicit, reversible session choice.

## Default behavior follows the permission mode

The preference has three values: `auto` (default), `on`, and `off`. In `auto`
the effective mode is derived from the permission mode of the turn:

| Permission mode | Effective bash-first |
|---|---|
| `ask` | off (standard projection) |
| `auto` | on |
| `yolo` | on |

Approval-free modes already let the model run shell commands without stopping,
so the overlapping discovery helpers add no safety value there and the `rg`
contract is used by default. Switching the permission mode (`/permissions`,
ACP `mode`) changes the effective projection on the next turn without
touching the preference. `on` and `off` are explicit overrides that ignore the
permission mode.

Bash-first is only applied when the projected tool set actually advertises
`exec_command`. A tool set without the unified shell keeps the specialized
discovery tools and receives no `rg` guidance, whatever the preference says.

## TUI

Use `/bash-first` to toggle the effective mode, or pass `/bash-first on`,
`/bash-first off`, or `/bash-first auto` for an explicit setting. The change
is announced in the transcript and applies to the next model turn; a running
turn keeps its tool projection snapshot. `/bash-first auto` announces the
value that is effective for the current permission mode, and `/trace` reports
record both the preference and the effective value, for example
`bash_first: auto (enabled)`.

## ACP

Native ACP advertises the capability as `_meta.fx.toolModes.bashFirst`. Set it
without waiting for an active prompt:

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "fx/toolMode/set",
  "params": {"mode": "bash-first"}
}
```

The response is `{"mode":"bash-first","bashFirst":true}`. Use
`{"bashFirst":false}` or `{"mode":"standard"}` to force the standard
projection, and `{"mode":"auto"}` to return to the permission-mode-derived
default. `mode` in the response echoes the stored preference
(`bash-first`, `standard`, or `auto`), while `bashFirst` reports the value
that is effective for the active session's permission mode. The same state is
also exposed as the `bash_first` session config option (`auto|off|on`) for
clients that use `session/set_config_option` while no prompt is running.

The setting is connection-local and is not written into durable conversation
history. This prevents a tool-advertisement preference from changing the
meaning of an existing saved turn; a new ACP connection starts in `auto`.

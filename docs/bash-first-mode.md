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

## TUI

Use `/bash-first` to toggle the mode, or pass `/bash-first on` and
`/bash-first off` for an explicit setting. The change is announced in the
transcript and applies to the next model turn; a running turn keeps its tool
projection snapshot.

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
`{"bashFirst":false}` or `{"mode":"standard"}` to restore the default.
The same state is also exposed as the `bash_first` session config option for
clients that use `session/set_config_option` while no prompt is running.

The setting is connection-local and is not written into durable conversation
history. This prevents a tool-advertisement preference from changing the
meaning of an existing saved turn; a new ACP connection starts in standard
mode.

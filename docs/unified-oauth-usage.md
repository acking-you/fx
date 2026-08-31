# Unified OAuth and usage

The Codex and Grok subscription integrations share one provider-neutral OAuth
boundary in `src/core/auth/provider_oauth.zig`. Provider modules still own
their protocol details, but login start, stored-session detection, credential
loading, refresh mode, account identity, and TUI/ACP routing all use the same
interface.

The independent `fx setup` importer uses that same boundary without reviving
the removed vendor onboarding flow. It discovers compatible Codex CLI and
Grok Build OAuth files, copies only missing provider sessions into fx's private
profile, and preserves Grok team-principal refresh metadata. TUI `/setup` and
ACP `fx/provider/setup/start` plus `fx/provider/setup/status` run the import on
a worker so their event loops remain responsive.

`fx/provider/login/start` accepts an optional `provider`. When it is omitted,
fx checks stored OAuth sessions in deterministic order (Codex first, Grok as a
fallback) without making a network request. An explicit provider remains
strict: a Codex credential is never sent to Grok and vice versa.

Usage is represented by `src/core/session/provider_usage.zig`. It is an
aggregate-only snapshot and never includes access tokens. The TUI footer and
ACP both consume this same summary. After a turn has reported token usage, the
footer shows a compact `Usage: Nk` segment. ACP clients can request the local,
non-blocking snapshot at any time:

```json
{"jsonrpc":"2.0","id":7,"method":"fx/provider/usage","params":{}}
```

The result contains `provider`, `credentialSource`, whether an account identity
is present, input/output/total token counts, request count, and context
fields. This endpoint reads the in-process session ledger only; it does not
perform remote quota I/O on the ACP read loop. Account-wide Codex limits remain
available through `fx usage --codex`, while provider-specific remote quota
lookups can be added behind the same summary without changing the TUI or ACP
contract.

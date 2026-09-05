# Native embedding

`zig build libfx` builds a position-independent static library at
`zig-out/lib/libfx_core.a`. The C ABI is declared in `include/fx.h`.
`zig build test-embedded` runs focused embedding boundary tests.

The library starts the ordinary native ACP engine on an owned worker. It uses
private, bounded byte queues instead of process stdin and stdout. The host
retains the runtime independently from external ACP attachments and multiplexes
its SDK and client requests onto that engine. One engine has one loaded native
session and one active root turn. Independent engines can run concurrently.

Create accepts UTF-8 JSON with absolute `home` and `workspace_root` paths.
Optional fields include `model`, `provider`, `api_key`, `responses_base_url`,
`instructions`, `native_tools`, `environment`, and `tools`. Environment entries
are `{ "key": "NAME", "value": "VALUE" }`. Provider environment variables are
excluded unless explicitly supplied or `inherit_provider_environment` is true.
The host process environment and working directory are never changed.

Every worker inherits an immutable, reference-counted environment snapshot.
Subprocesses inherit that instance snapshot unless their caller supplies an
explicit environment. The CLI path retains its existing process environment.
The process-wide native I/O driver remains allocated until process exit.

Tools contain `name`, `description`, `parameters` (an object JSON schema), and
`read_only` (false by default). Native and historical executable tool names are
reserved. Host tools pass through ordinary fx admission before a private
`_harnel/tool/call` request is sent to the host. The host replies with
`{ "output": "text", "is_error": false }`. The host owns argument validation
and callback cancellation. Schemas describe the model contract; they are not
a substitute for validation inside a tool implementation.

Frames use native ACP JSON-RPC framing. The host must consume output continuously,
answer outbound permission/tool requests, and bound its own queues. Native
queues hold at most 8 MiB each. Backpressure is an explicit error, and output
overflow closes the engine. Close stops command admission and cancels active
work. Destroy joins workers before freeing the handle. The caller must finish
all concurrent ABI calls before destroying it.

`fx/provider/status`, `fx/provider/logout`, and `fx/provider/refresh` expose
credential lifecycle control. Logout and refresh run away from the ACP reader;
refresh applies to Codex and Grok and activates the refreshed provider. Logout
removes stored credentials and suppresses automatic credential reloading in the
current engine until an explicit activation. No credential bytes appear in
these responses. `session/remove` deletes the loaded session using its existing
writer lease and closes that session first.

Unified Exec runs directly in the embedded process. Legacy terminal paths that
require re-executing fx return `EmbeddedHelperUnavailable` unless the host sets
an absolute `FX_EMBEDDED_HELPER` path. They never re-execute the embedding app.

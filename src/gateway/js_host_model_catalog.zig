const model_catalog = @import("../core/gateway/model_catalog.zig");
const host_model_catalog = @import("host_model_catalog.zig");
const js_host_stream_provider = @import("js_host_stream_provider.zig");

const provider_context = host_model_catalog.initContext(js_host_stream_provider.transport());

pub const provider: model_catalog.Provider = host_model_catalog.provider(@constCast(&provider_context));
pub const cli_provider = host_model_catalog.cliProvider(@constCast(&provider_context));

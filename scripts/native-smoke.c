#include "fx.h"
#include <stdio.h>
#include <string.h>

/* Exercise the public header and archive from an ordinary C host. */
int main(int argc, char **argv) {
    if (argc != 3 || fx_abi_version() != 1 || strcmp(fx_revision(), argv[2]) != 0)
        return 1;
    FILE *config = fopen(argv[1], "rb");
    if (!config) return 2;
    unsigned char bytes[65536];
    size_t length = fread(bytes, 1, sizeof(bytes), config);
    fclose(config);
    fx_runtime *runtime = NULL;
    if (fx_runtime_create(bytes, length, &runtime) != FX_OK) {
        fprintf(stderr, "%s\n", fx_last_error());
        return 3;
    }
    const char request[] = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1}}\n";
    int result = 0;
    if (fx_runtime_write(runtime, (const uint8_t *)request, strlen(request)) != FX_OK) {
        result = 4;
    } else {
        size_t used = 0;
        while (used < sizeof(bytes) - 1) {
            size_t written = 0;
            if (fx_runtime_read(runtime, bytes + used, sizeof(bytes) - 1 - used, &written) != FX_OK || !written)
                break;
            used += written;
            if (memchr(bytes, '\n', used)) break;
        }
        bytes[used] = 0;
        if (!strstr((char *)bytes, "\"result\"") || !strstr((char *)bytes, "\"agentInfo\""))
            result = 5;
    }
    fx_runtime_close(runtime);
    /* Drain to EOF so the worker has settled before observing its exit code. */
    size_t written = 0;
    while (fx_runtime_read(runtime, bytes, sizeof(bytes), &written) == FX_OK && written) {}
    if (fx_runtime_exit_code(runtime)) result = 6;
    fx_runtime_destroy(runtime);
    if (!result) puts("Native C ABI initialization and shutdown passed.");
    return result;
}

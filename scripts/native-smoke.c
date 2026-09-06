#include "fx.h"
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

#ifdef _WIN32
static DWORD WINAPI forward_output(void *context) {
#else
static void *forward_output(void *context) {
#endif
    fx_runtime *runtime = context;
    uint8_t bytes[65536];
    size_t written = 0;
    while (fx_runtime_read(runtime, bytes, sizeof(bytes), &written) == FX_OK && written) {
        if (fwrite(bytes, 1, written, stdout) != written || fflush(stdout)) break;
    }
    return 0;
}

static int bridge(fx_runtime *runtime) {
#ifdef _WIN32
    HANDLE reader = CreateThread(NULL, 0, forward_output, runtime, 0, NULL);
    if (!reader) return 7;
#else
    pthread_t reader;
    if (pthread_create(&reader, NULL, forward_output, runtime)) return 7;
#endif
    char line[65536];
    int result = 0;
    while (fgets(line, sizeof(line), stdin)) {
        if (fx_runtime_write(runtime, (const uint8_t *)line, strlen(line)) != FX_OK) {
            result = 8;
            break;
        }
    }
    fx_runtime_close(runtime);
#ifdef _WIN32
    WaitForSingleObject(reader, INFINITE);
    CloseHandle(reader);
#else
    pthread_join(reader, NULL);
#endif
    return result;
}

/* Exercise the public header and archive from an ordinary C host. */
int main(int argc, char **argv) {
    const int use_bridge = argc == 4 && strcmp(argv[3], "--bridge") == 0;
    if ((argc != 3 && !use_bridge) || fx_abi_version() != 1 || strcmp(fx_revision(), argv[2]) != 0)
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
    if (use_bridge) {
        int result = bridge(runtime);
        if (fx_runtime_exit_code(runtime)) result = 6;
        fx_runtime_destroy(runtime);
        return result;
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

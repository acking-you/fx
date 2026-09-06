#ifndef FX_H
#define FX_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct fx_runtime fx_runtime;
enum fx_status {
    FX_OK = 0,
    FX_INVALID_ARGUMENT = 1,
    FX_ERROR = 2,
    FX_CLOSED = 3,
    FX_BACKPRESSURE = 4,
    FX_OUT_OF_MEMORY = 5
};

/* ABI 1. Buffers passed to create/write are copied before returning. Read
 * writes into caller-owned memory and blocks until data or EOF is available.
 * Close is idempotent and wakes the control reader. Destroy joins the worker;
 * the host must finish all concurrent read/write calls before destruction.
 * Calls never use stdin/stdout or change the host's environment or cwd. */
uint32_t fx_abi_version(void);
const char *fx_revision(void);
/* Thread-local error text, valid until the next failing call on that thread. */
const char *fx_last_error(void);
int fx_runtime_create(const uint8_t *config, size_t length, fx_runtime **output);
int fx_runtime_write(fx_runtime *runtime, const uint8_t *bytes, size_t length);
int fx_runtime_read(fx_runtime *runtime, uint8_t *buffer, size_t capacity, size_t *written);
void fx_runtime_close(fx_runtime *runtime);
uint32_t fx_runtime_exit_code(fx_runtime *runtime);
void fx_runtime_destroy(fx_runtime *runtime);

#ifdef __cplusplus
}
#endif
#endif

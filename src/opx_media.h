// OpenPlayX in-process media bridge: a small, versioned C ABI owned by this
// package. FFmpeg structures never cross this boundary; Dart only sees the
// opaque job handle, UTF-8 JSON documents and the fixed event struct below.
//
// No function here starts a process, a shell or the ffmpeg/ffprobe programs.
#ifndef OPX_MEDIA_H
#define OPX_MEDIA_H

#include <stdint.h>

#if defined(_WIN32)
#define OPX_API __declspec(dllexport)
#else
#define OPX_API __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define OPX_MEDIA_ABI 1

// Result / error codes (stable across ABI 1).
enum {
  OPX_OK = 0,
  OPX_E_INVALID_ARGUMENT = 1,
  OPX_E_INPUT_UNAVAILABLE = 2,
  OPX_E_INPUT_UNSUPPORTED = 3,
  OPX_E_ENCODER_UNAVAILABLE = 4,
  OPX_E_PRESET_INCOMPATIBLE = 5,
  OPX_E_NO_SPACE = 6,
  OPX_E_NATIVE_FAILURE = 7,
  OPX_E_TIMEOUT = 8,
  OPX_E_CANCELLED = 9,
  OPX_E_ACCESS_DENIED = 10,
  OPX_E_BAD_STATE = 11,
};

// Job states reported by opx_media_job_poll.
enum {
  OPX_STATE_CREATED = 0,
  OPX_STATE_PREPARING = 1,
  OPX_STATE_RUNNING = 2,
  OPX_STATE_FINALIZING = 3,
  OPX_STATE_SUCCEEDED = 4,
  OPX_STATE_FAILED = 5,
  OPX_STATE_CANCELLED = 6,
};

typedef struct opx_media_job opx_media_job;

// Fixed-layout snapshot of a job; the newest state replaces older progress,
// so the "queue" is bounded to one entry and never blocks the worker.
typedef struct {
  int32_t state;
  int32_t error;
  int64_t processed_us;  // input time handled so far, relative to the start
  int64_t total_us;      // effective duration, <= 0 when unknown
  int64_t sequence;      // increments on each change
} opx_media_event;

OPX_API uint32_t opx_media_abi_version(void);

// Build/device capabilities as JSON. Encoders listed as usable were opened
// successfully on this device. Free with opx_media_string_free.
OPX_API char *opx_media_capabilities(void);

// input_json: {"input": "<absolute path | http://127.0.0.1:port/...>",
//              "timeout_ms": 15000}
// On OPX_OK *result_json receives a sanitized probe document.
OPX_API int32_t opx_media_probe(const char *input_json, char **result_json);
OPX_API void opx_media_string_free(char *value);

// plan_json is deep-copied; see opx_media.c for the keys of each operation.
OPX_API int32_t opx_media_job_create(const char *plan_json,
                                     opx_media_job **job);
OPX_API int32_t opx_media_job_start(opx_media_job *job);
// Non-blocking. Returns 1 when the event changed since the previous poll,
// 0 when unchanged, or a negative value on invalid arguments.
OPX_API int32_t opx_media_job_poll(opx_media_job *job, opx_media_event *event);
// Cooperative: sets a flag checked by FFmpeg's interrupt callback and the
// processing loops. The job keeps running until it observes the flag.
OPX_API int32_t opx_media_job_cancel(opx_media_job *job);
// Waits for the worker thread. Call only after a terminal poll state (it is
// then immediate) or from a thread that may block.
OPX_API int32_t opx_media_job_join(opx_media_job *job);
// Only valid for jobs never started or already joined.
OPX_API void opx_media_job_destroy(opx_media_job *job);

#ifdef __cplusplus
}
#endif

#endif

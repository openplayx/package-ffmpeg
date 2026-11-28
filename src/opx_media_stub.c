// Built when no pinned FFmpeg exists for the target (e.g. a Windows build
// without tool output): the ABI is present but reports itself unavailable,
// so the app builds and runs, and capabilities show the real state.
#include <stdlib.h>
#include <string.h>

#include "opx_media.h"

uint32_t opx_media_abi_version(void) { return OPX_MEDIA_ABI; }
char *opx_media_capabilities(void) {
  const char *text =
      "{\"abi\":1,\"available\":false,\"encoders\":[],\"muxers\":[],"
      "\"decoders\":[]}";
  size_t size = strlen(text) + 1;
  char *copy = malloc(size);
  if (copy) memcpy(copy, text, size);
  return copy;
}
int32_t opx_media_probe(const char *input_json, char **result_json) {
  (void)input_json;
  if (result_json) *result_json = NULL;
  return OPX_E_ENCODER_UNAVAILABLE;
}
void opx_media_string_free(char *value) { free(value); }
int32_t opx_media_job_create(const char *plan_json, opx_media_job **job) {
  (void)plan_json;
  if (job) *job = NULL;
  return OPX_E_ENCODER_UNAVAILABLE;
}
int32_t opx_media_job_start(opx_media_job *job) { (void)job; return OPX_E_BAD_STATE; }
int32_t opx_media_job_poll(opx_media_job *job, opx_media_event *event) {
  (void)job; (void)event; return -1;
}
int32_t opx_media_job_cancel(opx_media_job *job) { (void)job; return OPX_E_BAD_STATE; }
int32_t opx_media_job_join(opx_media_job *job) { (void)job; return OPX_E_BAD_STATE; }
void opx_media_job_destroy(opx_media_job *job) { (void)job; }

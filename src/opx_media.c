// In-process media processing on FFmpeg's public library APIs
// (libavformat/libavcodec/libavutil/libswscale/libswresample).
//
// Plan keys (flat JSON object produced by the Dart host, never by a model):
//   operation   "snapshot" | "remux" | "transcode"
//   input       absolute path, or a loopback http URL owned by the host
//   output      absolute path of a temporary file (deleted on failure)
//   format      muxer name for remux/transcode ("mp4", "ipod", "wav", ...)
//   video_stream / audio_stream / subtitle_stream  input stream index or -1
//   video_mode / audio_mode / subtitle_mode        "copy" | "encode" | "none"
//   start_us, end_us   optional trim (end_us <= 0: until the end)
//   time_us            snapshot position
//   max_long, max_short  bounding box for scaled video/images (0: keep)
//   video_codec, video_bitrate, audio_codec, audio_bitrate,
//   sample_rate, channels, image_quality, timeout_ms

#include "opx_media.h"

#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/display.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/time.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#if defined(_WIN32)
#include <windows.h>
typedef HANDLE opx_thread;
typedef CRITICAL_SECTION opx_mutex;
#define mutex_init(m) InitializeCriticalSection(m)
#define mutex_lock(m) EnterCriticalSection(m)
#define mutex_unlock(m) LeaveCriticalSection(m)
#define mutex_destroy(m) DeleteCriticalSection(m)
#define unlink_file(p) _unlink(p)
#include <io.h>
#else
#include <pthread.h>
#include <unistd.h>
typedef pthread_t opx_thread;
typedef pthread_mutex_t opx_mutex;
#define mutex_init(m) pthread_mutex_init(m, NULL)
#define mutex_lock(m) pthread_mutex_lock(m)
#define mutex_unlock(m) pthread_mutex_unlock(m)
#define mutex_destroy(m) pthread_mutex_destroy(m)
#define unlink_file(p) unlink(p)
#endif

#define OPX_MAX_TEXT 4096
#define OPX_MAX_PLAN (64 * 1024)

// ------------------------------------------------------------------ strings

typedef struct {
  char *data;
  size_t len, cap;
  int failed;
} sbuf;

static void sb_put(sbuf *b, const char *s, size_t n) {
  if (b->failed) return;
  if (b->len + n + 1 > b->cap) {
    size_t cap = b->cap ? b->cap * 2 : 1024;
    while (cap < b->len + n + 1) cap *= 2;
    char *next = realloc(b->data, cap);
    if (!next) {
      b->failed = 1;
      return;
    }
    b->data = next;
    b->cap = cap;
  }
  memcpy(b->data + b->len, s, n);
  b->len += n;
  b->data[b->len] = 0;
}

static void sb_printf(sbuf *b, const char *fmt, ...) {
  char tmp[512];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
  va_end(ap);
  if (n < 0) return;
  sb_put(b, tmp, (size_t)(n < (int)sizeof tmp ? n : (int)sizeof tmp - 1));
}

// Writes a JSON string; control characters are escaped, text is truncated.
static void sb_json(sbuf *b, const char *s) {
  sb_put(b, "\"", 1);
  size_t count = 0;
  for (const unsigned char *p = (const unsigned char *)(s ? s : "");
       *p && count < 200; p++, count++) {
    if (*p == '"' || *p == '\\') {
      char esc[2] = {'\\', (char)*p};
      sb_put(b, esc, 2);
    } else if (*p < 0x20) {
      sb_printf(b, "\\u%04x", *p);
    } else {
      sb_put(b, (const char *)p, 1);
    }
  }
  sb_put(b, "\"", 1);
}

static char *sb_take(sbuf *b) {
  if (b->failed) {
    free(b->data);
    return NULL;
  }
  return b->data;
}

// ---------------------------------------------------- flat JSON object reader

static const char *skip_ws(const char *p) {
  while (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t') p++;
  return p;
}

static int hexval(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// Parses a JSON string at p (pointing to '"'); writes up to cap-1 bytes.
static const char *parse_string(const char *p, char *out, size_t cap,
                                int *ok) {
  size_t n = 0;
  *ok = 0;
  if (*p != '"') return p;
  p++;
  while (*p && *p != '"') {
    unsigned code = (unsigned char)*p++;
    if (code == '\\') {
      char e = *p++;
      switch (e) {
        case 'n': code = '\n'; break;
        case 't': code = '\t'; break;
        case 'r': code = '\r'; break;
        case 'b': code = '\b'; break;
        case 'f': code = '\f'; break;
        case 'u': {
          code = 0;
          for (int i = 0; i < 4; i++) {
            int h = hexval(*p++);
            if (h < 0) return p;
            code = code * 16 + (unsigned)h;
          }
          if (code >= 0xD800 && code <= 0xDBFF && p[0] == '\\' &&
              p[1] == 'u') {
            unsigned low = 0;
            for (int i = 0; i < 4; i++) {
              int h = hexval(p[2 + i]);
              if (h < 0) return p;
              low = low * 16 + (unsigned)h;
            }
            if (low >= 0xDC00 && low <= 0xDFFF) {
              code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
              p += 6;
            }
          }
          break;
        }
        case 0: return p;
        default: code = (unsigned char)e;
      }
    }
    char enc[4];
    size_t len;
    if (code < 0x80) {
      enc[0] = (char)code;
      len = 1;
    } else if (code < 0x800) {
      enc[0] = (char)(0xC0 | (code >> 6));
      enc[1] = (char)(0x80 | (code & 0x3F));
      len = 2;
    } else if (code < 0x10000) {
      enc[0] = (char)(0xE0 | (code >> 12));
      enc[1] = (char)(0x80 | ((code >> 6) & 0x3F));
      enc[2] = (char)(0x80 | (code & 0x3F));
      len = 3;
    } else {
      enc[0] = (char)(0xF0 | (code >> 18));
      enc[1] = (char)(0x80 | ((code >> 12) & 0x3F));
      enc[2] = (char)(0x80 | ((code >> 6) & 0x3F));
      enc[3] = (char)(0x80 | (code & 0x3F));
      len = 4;
    }
    if (n + len >= cap) return p;  // too long: reject
    memcpy(out + n, enc, len);
    n += len;
  }
  if (*p != '"') return p;
  out[n] = 0;
  *ok = 1;
  return p + 1;
}

// Finds a top-level key and copies its raw scalar value (string decoded).
// Returns 1 for strings, 2 for other scalars, 0 if missing or malformed.
static int json_find(const char *json, const char *key, char *out,
                     size_t cap) {
  char name[128];
  int ok;
  const char *p = skip_ws(json);
  if (*p++ != '{') return 0;
  for (;;) {
    p = skip_ws(p);
    if (*p == '}') return 0;
    p = parse_string(p, name, sizeof name, &ok);
    if (!ok) return 0;
    p = skip_ws(p);
    if (*p++ != ':') return 0;
    p = skip_ws(p);
    int match = strcmp(name, key) == 0;
    if (*p == '"') {
      char *dst = match ? out : NULL;
      char scratch[OPX_MAX_TEXT];
      p = parse_string(p, dst ? dst : scratch, dst ? cap : sizeof scratch,
                       &ok);
      if (!ok) return 0;
      if (match) return 1;
    } else {
      const char *start = p;
      while (*p && *p != ',' && *p != '}' && *p != ' ' && *p != '\n') p++;
      if (p == start || *start == '{' || *start == '[') return 0;
      if (match) {
        size_t n = (size_t)(p - start);
        if (n >= cap) return 0;
        memcpy(out, start, n);
        out[n] = 0;
        return 2;
      }
    }
    p = skip_ws(p);
    if (*p == ',') {
      p++;
      continue;
    }
    return 0;
  }
}

static int64_t json_i64(const char *json, const char *key, int64_t fallback) {
  char v[64];
  if (json_find(json, key, v, sizeof v) != 2) return fallback;
  char *end;
  errno = 0;
  long long n = strtoll(v, &end, 10);
  if (errno || *end) return fallback;
  return n;
}

static int json_str(const char *json, const char *key, char *out,
                    size_t cap) {
  out[0] = 0;
  return json_find(json, key, out, cap) == 1;
}

// ------------------------------------------------------------ input policy

static int is_loopback_http(const char *url) {
  const char *prefixes[] = {"http://127.0.0.1:", "http://localhost:"};
  for (int i = 0; i < 2; i++) {
    size_t n = strlen(prefixes[i]);
    if (strncmp(url, prefixes[i], n) == 0) {
      const char *p = url + n;
      if (*p < '0' || *p > '9') return 0;
      while (*p >= '0' && *p <= '9') p++;
      return *p == '/';
    }
  }
  return 0;
}

static int is_absolute_path(const char *path) {
  if (!path[0] || strstr(path, "://")) return 0;
#if defined(_WIN32)
  return ((path[0] | 32) >= 'a' && (path[0] | 32) <= 'z' && path[1] == ':' &&
          (path[2] == '\\' || path[2] == '/'));
#else
  return path[0] == '/';
#endif
}

typedef struct {
  volatile int *cancel;
  int64_t deadline;  // av_gettime_relative() microseconds, 0 = none
  int timed_out;
  const char *only_url;  // every (secondary) open must match exactly
  int (*io_open_default)(struct AVFormatContext *, AVIOContext **,
                         const char *, int, AVDictionary **);
} io_guard;

static int interrupt_cb(void *opaque) {
  io_guard *g = opaque;
  if (g->cancel && *g->cancel) return 1;
  if (g->deadline && av_gettime_relative() > g->deadline) {
    g->timed_out = 1;
    return 1;
  }
  return 0;
}

// Rejects playlists, references and nested protocols: only the top-level
// input itself may be opened by the demuxer.
static int guarded_io_open(struct AVFormatContext *s, AVIOContext **pb,
                           const char *url, int flags, AVDictionary **opts) {
  io_guard *g = s->opaque;
  if (!g || !url || strcmp(url, g->only_url) != 0) return AVERROR(EPERM);
  return g->io_open_default(s, pb, url, flags, opts);
}

static int map_av_error(int err, const io_guard *g, volatile int *cancel) {
  if (cancel && *cancel) return OPX_E_CANCELLED;
  if (g && g->timed_out) return OPX_E_TIMEOUT;
  if (err == AVERROR(ENOSPC)) return OPX_E_NO_SPACE;
  if (err == AVERROR(EPERM) || err == AVERROR(EACCES))
    return OPX_E_ACCESS_DENIED;
  if (err == AVERROR(ENOENT) || err == AVERROR(EIO) ||
      err == AVERROR_HTTP_NOT_FOUND || err == AVERROR_HTTP_FORBIDDEN ||
      err == AVERROR(ECONNREFUSED) || err == AVERROR(ETIMEDOUT))
    return OPX_E_INPUT_UNAVAILABLE;
  if (err == AVERROR_INVALIDDATA || err == AVERROR_DECODER_NOT_FOUND ||
      err == AVERROR_DEMUXER_NOT_FOUND || err == AVERROR_PATCHWELCOME)
    return OPX_E_INPUT_UNSUPPORTED;
  if (err == AVERROR_ENCODER_NOT_FOUND) return OPX_E_ENCODER_UNAVAILABLE;
  if (err == AVERROR_EXIT) return OPX_E_CANCELLED;
  return OPX_E_NATIVE_FAILURE;
}

static void quiet_log(void *ptr, int level, const char *fmt, va_list vl) {
  (void)ptr;
  (void)level;
  (void)fmt;
  (void)vl;  // Raw FFmpeg logs can contain paths; never forwarded.
}

static void global_init(void) {
  static volatile int done = 0;
  if (!done) {
    // One global callback for the process, not one per job.
    av_log_set_callback(quiet_log);
    done = 1;
  }
}

static int open_input(const char *url, io_guard *g, AVFormatContext **out) {
  int local = is_absolute_path(url);
  if (!local && !is_loopback_http(url)) return AVERROR(EPERM);
  AVFormatContext *ctx = avformat_alloc_context();
  if (!ctx) return AVERROR(ENOMEM);
  g->only_url = url;
  g->io_open_default = ctx->io_open;
  ctx->opaque = g;
  ctx->io_open = guarded_io_open;
  ctx->interrupt_callback.callback = interrupt_cb;
  ctx->interrupt_callback.opaque = g;
  ctx->probesize = 10 * 1024 * 1024;
  ctx->max_analyze_duration = 10 * AV_TIME_BASE;
  AVDictionary *opts = NULL;
  av_dict_set(&opts, "protocol_whitelist", local ? "file" : "http,tcp", 0);
  if (!local) {
    av_dict_set(&opts, "rw_timeout", "20000000", 0);
    av_dict_set(&opts, "reconnect", "0", 0);
  }
  int err = avformat_open_input(&ctx, url, NULL, &opts);
  av_dict_free(&opts);
  if (err < 0) return err;  // ctx freed by FFmpeg on failure
  err = avformat_find_stream_info(ctx, NULL);
  if (err < 0) {
    avformat_close_input(&ctx);
    return err;
  }
  *out = ctx;
  return 0;
}

static double stream_rotation(const AVStream *st) {
  const AVPacketSideData *sd =
      av_packet_side_data_get(st->codecpar->coded_side_data,
                              st->codecpar->nb_coded_side_data,
                              AV_PKT_DATA_DISPLAYMATRIX);
  if (!sd || sd->size < 9 * 4) return 0;
  double r = -av_display_rotation_get((const int32_t *)sd->data);
  if (r != r) return 0;  // NaN
  while (r < 0) r += 360;
  while (r >= 360) r -= 360;
  return r;
}

// ------------------------------------------------------------- public: info

uint32_t opx_media_abi_version(void) { return OPX_MEDIA_ABI; }

void opx_media_string_free(char *value) { free(value); }

static int encoder_usable(const char *name) {
  const AVCodec *codec = avcodec_find_encoder_by_name(name);
  if (!codec) return 0;
  if (codec->type != AVMEDIA_TYPE_VIDEO) return 1;
  // Hardware encoders can be built in yet unavailable on this device:
  // only report what actually opens here.
  AVCodecContext *ctx = avcodec_alloc_context3(codec);
  if (!ctx) return 0;
  ctx->width = 640;
  ctx->height = 360;
  ctx->time_base = (AVRational){1, 25};
  ctx->framerate = (AVRational){25, 1};
  ctx->pix_fmt = AV_PIX_FMT_YUV420P;
  if (strcmp(name, "png") == 0) ctx->pix_fmt = AV_PIX_FMT_RGB24;
  if (strcmp(name, "mjpeg") == 0) ctx->pix_fmt = AV_PIX_FMT_YUVJ420P;
  ctx->bit_rate = 1000000;
  int ok = avcodec_open2(ctx, codec, NULL) >= 0;
  avcodec_free_context(&ctx);
  return ok;
}

char *opx_media_capabilities(void) {
  global_init();
  static const char *encoders[] = {"h264_videotoolbox", "h264_mediacodec",
                                   "mpeg4", "aac", "pcm_s16le", "png",
                                   "mjpeg"};
  static const char *muxers[] = {"mp4", "ipod", "matroska", "wav", "mp3",
                                 "flac"};
  sbuf b = {0};
  sb_printf(&b, "{\"abi\":%d,\"ffmpeg\":", OPX_MEDIA_ABI);
  sb_json(&b, av_version_info());
  sb_put(&b, ",\"encoders\":[", 13);
  int first = 1;
  for (size_t i = 0; i < sizeof encoders / sizeof *encoders; i++) {
    if (!encoder_usable(encoders[i])) continue;
    if (!first) sb_put(&b, ",", 1);
    sb_json(&b, encoders[i]);
    first = 0;
  }
  sb_put(&b, "],\"muxers\":[", 12);
  first = 1;
  for (size_t i = 0; i < sizeof muxers / sizeof *muxers; i++) {
    if (!av_guess_format(muxers[i], NULL, NULL)) continue;
    if (!first) sb_put(&b, ",", 1);
    sb_json(&b, muxers[i]);
    first = 0;
  }
  sb_put(&b, "],\"decoders\":[", 14);
  first = 1;
  void *it = NULL;
  const AVCodec *c;
  while ((c = av_codec_iterate(&it))) {
    if (!av_codec_is_decoder(c)) continue;
    if (!first) sb_put(&b, ",", 1);
    sb_json(&b, c->name);
    first = 0;
  }
  sb_put(&b, "]}", 2);
  return sb_take(&b);
}

static const char *media_type(enum AVMediaType t) {
  switch (t) {
    case AVMEDIA_TYPE_VIDEO: return "video";
    case AVMEDIA_TYPE_AUDIO: return "audio";
    case AVMEDIA_TYPE_SUBTITLE: return "subtitle";
    default: return "other";
  }
}

static void probe_json(AVFormatContext *ctx, sbuf *b) {
  sb_put(b, "{\"container\":", 13);
  sb_json(b, ctx->iformat ? ctx->iformat->name : "");
  sb_printf(b, ",\"duration_us\":%lld,\"bit_rate\":%lld,\"streams\":[",
            (long long)(ctx->duration > 0 ? ctx->duration : 0),
            (long long)ctx->bit_rate);
  for (unsigned i = 0; i < ctx->nb_streams; i++) {
    AVStream *st = ctx->streams[i];
    AVCodecParameters *p = st->codecpar;
    if (i) sb_put(b, ",", 1);
    sb_printf(b, "{\"index\":%u,\"type\":", i);
    sb_json(b, media_type(p->codec_type));
    sb_put(b, ",\"codec\":", 9);
    sb_json(b, avcodec_get_name(p->codec_id));
    sb_printf(b, ",\"decodable\":%s",
              avcodec_find_decoder(p->codec_id) ? "true" : "false");
    int64_t dur = st->duration > 0 && st->time_base.den
                      ? av_rescale_q(st->duration, st->time_base,
                                     AV_TIME_BASE_Q)
                      : 0;
    sb_printf(b, ",\"duration_us\":%lld", (long long)dur);
    if (p->codec_type == AVMEDIA_TYPE_VIDEO) {
      AVRational fr = av_guess_frame_rate(ctx, st, NULL);
      const char *trc = av_color_transfer_name(p->color_trc);
      sb_printf(b,
                ",\"width\":%d,\"height\":%d,\"fps_num\":%d,\"fps_den\":%d,"
                "\"avg_fps_num\":%d,\"avg_fps_den\":%d,\"rotation\":%d,"
                "\"attached_pic\":%s,\"color_transfer\":",
                p->width, p->height, fr.num, fr.den, st->avg_frame_rate.num,
                st->avg_frame_rate.den, (int)(stream_rotation(st) + 0.5),
                (st->disposition & AV_DISPOSITION_ATTACHED_PIC) ? "true"
                                                                : "false");
      sb_json(b, trc ? trc : "unknown");
      sb_put(b, ",\"pixel_format\":", 16);
      const char *pf = av_get_pix_fmt_name((enum AVPixelFormat)p->format);
      sb_json(b, pf ? pf : "unknown");
    } else if (p->codec_type == AVMEDIA_TYPE_AUDIO) {
      sb_printf(b, ",\"sample_rate\":%d,\"channels\":%d", p->sample_rate,
                p->ch_layout.nb_channels);
    }
    const AVDictionaryEntry *lang = av_dict_get(st->metadata, "language",
                                                NULL, 0);
    const AVDictionaryEntry *title = av_dict_get(st->metadata, "title", NULL,
                                                 0);
    sb_put(b, ",\"language\":", 12);
    sb_json(b, lang ? lang->value : "");
    sb_put(b, ",\"title\":", 9);
    sb_json(b, title ? title->value : "");
    sb_printf(b, ",\"default\":%s}",
              (st->disposition & AV_DISPOSITION_DEFAULT) ? "true" : "false");
  }
  sb_put(b, "]}", 2);
}

int32_t opx_media_probe(const char *input_json, char **result_json) {
  if (!input_json || !result_json || strlen(input_json) > OPX_MAX_PLAN)
    return OPX_E_INVALID_ARGUMENT;
  *result_json = NULL;
  global_init();
  char url[OPX_MAX_TEXT];
  if (!json_str(input_json, "input", url, sizeof url))
    return OPX_E_INVALID_ARGUMENT;
  int64_t timeout = json_i64(input_json, "timeout_ms", 15000);
  if (timeout < 100 || timeout > 120000) timeout = 15000;
  io_guard g = {0};
  g.deadline = av_gettime_relative() + timeout * 1000;
  AVFormatContext *ctx = NULL;
  int err = open_input(url, &g, &ctx);
  if (err < 0) return map_av_error(err, &g, NULL);
  sbuf b = {0};
  probe_json(ctx, &b);
  avformat_close_input(&ctx);
  *result_json = sb_take(&b);
  return *result_json ? OPX_OK : OPX_E_NATIVE_FAILURE;
}

// --------------------------------------------------------------------- jobs

struct opx_media_job {
  char *plan;
  opx_mutex lock;
  opx_media_event event;
  int64_t last_polled;
  volatile int cancel;
  int started, joined;
  opx_thread thread;
};

static void job_update(opx_media_job *job, int state, int error,
                       int64_t processed, int64_t total) {
  mutex_lock(&job->lock);
  if (state >= 0) job->event.state = state;
  if (error >= 0) job->event.error = error;
  if (processed >= 0) job->event.processed_us = processed;
  if (total != INT64_MIN) job->event.total_us = total;
  job->event.sequence++;
  mutex_unlock(&job->lock);
}

int32_t opx_media_job_create(const char *plan_json, opx_media_job **job) {
  if (!plan_json || !job) return OPX_E_INVALID_ARGUMENT;
  size_t n = strlen(plan_json);
  if (n == 0 || n > OPX_MAX_PLAN) return OPX_E_INVALID_ARGUMENT;
  char op[32], input[OPX_MAX_TEXT], output[OPX_MAX_TEXT];
  if (!json_str(plan_json, "operation", op, sizeof op) ||
      !json_str(plan_json, "input", input, sizeof input) ||
      !json_str(plan_json, "output", output, sizeof output))
    return OPX_E_INVALID_ARGUMENT;
  if (strcmp(op, "snapshot") && strcmp(op, "remux") && strcmp(op, "transcode"))
    return OPX_E_INVALID_ARGUMENT;
  if (!is_absolute_path(output)) return OPX_E_ACCESS_DENIED;
  if (!is_absolute_path(input) && !is_loopback_http(input))
    return OPX_E_ACCESS_DENIED;
  opx_media_job *j = calloc(1, sizeof *j);
  if (!j) return OPX_E_NATIVE_FAILURE;
  j->plan = malloc(n + 1);  // deep copy: Dart may free its buffer now
  if (!j->plan) {
    free(j);
    return OPX_E_NATIVE_FAILURE;
  }
  memcpy(j->plan, plan_json, n + 1);
  mutex_init(&j->lock);
  j->last_polled = -1;
  *job = j;
  return OPX_OK;
}

int32_t opx_media_job_poll(opx_media_job *job, opx_media_event *event) {
  if (!job || !event) return -1;
  mutex_lock(&job->lock);
  *event = job->event;
  int changed = job->event.sequence != job->last_polled;
  job->last_polled = job->event.sequence;
  mutex_unlock(&job->lock);
  return changed;
}

int32_t opx_media_job_cancel(opx_media_job *job) {
  if (!job) return OPX_E_INVALID_ARGUMENT;
  job->cancel = 1;
  return OPX_OK;
}

// ----------------------------------------------------------- job: helpers

typedef struct {
  opx_media_job *job;
  const char *plan;
  io_guard guard;
  AVFormatContext *in, *out;
  char output[OPX_MAX_TEXT];
  int64_t start_us, end_us, total_us;
  int64_t last_report;
} worker;

static void fit_box(int w, int h, int max_long, int max_short, int *ow,
                    int *oh) {
  double scale = 1.0;
  int lng = w > h ? w : h, sht = w > h ? h : w;
  if (max_long > 0 && lng > max_long) scale = (double)max_long / lng;
  if (max_short > 0 && sht * scale > max_short)
    scale = (double)max_short / sht;
  if (scale > 1.0) scale = 1.0;  // never upscale
  *ow = ((int)(w * scale + 0.5)) & ~1;
  *oh = ((int)(h * scale + 0.5)) & ~1;
  if (*ow < 2) *ow = 2;
  if (*oh < 2) *oh = 2;
}

static void report(worker *w, int64_t pts_us) {
  if (pts_us == AV_NOPTS_VALUE) return;
  int64_t done = pts_us - w->start_us;
  if (done < 0) done = 0;
  if (w->total_us > 0 && done > w->total_us) done = w->total_us;
  int64_t now = av_gettime_relative();
  if (now - w->last_report < 200000) return;  // throttled
  w->last_report = now;
  job_update(w->job, -1, -1, done, INT64_MIN);
}

static int cancelled(worker *w) { return w->job->cancel; }

static int write_file(const char *path, const uint8_t *data, int size) {
  FILE *f = fopen(path, "wb");
  if (!f) return AVERROR(errno ? errno : EIO);
  size_t n = fwrite(data, 1, (size_t)size, f);
  int err = ferror(f);
  if (fclose(f) != 0 || err || n != (size_t)size)
    return AVERROR(errno == ENOSPC ? ENOSPC : EIO);
  return 0;
}

static AVCodecContext *open_decoder(AVStream *st, int threads, int *err) {
  const AVCodec *dec = avcodec_find_decoder(st->codecpar->codec_id);
  if (!dec) {
    *err = AVERROR_DECODER_NOT_FOUND;
    return NULL;
  }
  AVCodecContext *ctx = avcodec_alloc_context3(dec);
  if (!ctx) {
    *err = AVERROR(ENOMEM);
    return NULL;
  }
  avcodec_parameters_to_context(ctx, st->codecpar);
  ctx->pkt_timebase = st->time_base;
  ctx->thread_count = threads;
  *err = avcodec_open2(ctx, dec, NULL);
  if (*err < 0) avcodec_free_context(&ctx);
  return ctx;
}

// Rotates a packed RGB24 image clockwise by 90/180/270 degrees.
static uint8_t *rotate_rgb(const uint8_t *src, int w, int h, int stride,
                           int degrees, int *ow, int *oh) {
  int rw = (degrees == 90 || degrees == 270) ? h : w;
  int rh = (degrees == 90 || degrees == 270) ? w : h;
  uint8_t *dst = av_malloc((size_t)rw * rh * 3);
  if (!dst) return NULL;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      int dx, dy;
      switch (degrees) {
        case 90: dx = h - 1 - y; dy = x; break;
        case 180: dx = w - 1 - x; dy = h - 1 - y; break;
        default: dx = y; dy = w - 1 - x; break;  // 270
      }
      memcpy(dst + ((size_t)dy * rw + dx) * 3, src + (size_t)y * stride + x * 3,
             3);
    }
  }
  *ow = rw;
  *oh = rh;
  return dst;
}

// ------------------------------------------------------------ job: snapshot

static int run_snapshot(worker *w) {
  int vindex = (int)json_i64(w->plan, "video_stream", -1);
  int64_t time_us = json_i64(w->plan, "time_us", 0);
  int max_long = (int)json_i64(w->plan, "max_long", 1280);
  int max_short = (int)json_i64(w->plan, "max_short", 720);
  int quality = (int)json_i64(w->plan, "image_quality", 3);
  char codec_name[16] = "mjpeg";
  json_str(w->plan, "image_codec", codec_name, sizeof codec_name);
  if (strcmp(codec_name, "mjpeg") && strcmp(codec_name, "png"))
    return AVERROR(EINVAL);
  if (vindex < 0)
    vindex = av_find_best_stream(w->in, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  if (vindex < 0 || vindex >= (int)w->in->nb_streams ||
      w->in->streams[vindex]->codecpar->codec_type != AVMEDIA_TYPE_VIDEO)
    return AVERROR_STREAM_NOT_FOUND;
  AVStream *st = w->in->streams[vindex];
  for (unsigned i = 0; i < w->in->nb_streams; i++)
    w->in->streams[i]->discard = (int)i == vindex ? AVDISCARD_DEFAULT
                                                  : AVDISCARD_ALL;
  w->start_us = 0;
  w->total_us = 0;
  int err = 0;
  AVCodecContext *dec = open_decoder(st, 2, &err);
  if (!dec) return err;
  AVPacket *pkt = av_packet_alloc();
  AVFrame *frame = av_frame_alloc();
  AVFrame *picked = NULL;
  struct SwsContext *sws = NULL;
  AVCodecContext *enc = NULL;
  uint8_t *rgb = NULL, *rotated = NULL;
  AVFrame *yuv = NULL;
  if (!pkt || !frame) {
    err = AVERROR(ENOMEM);
    goto done;
  }
  int64_t target = av_rescale_q(time_us, AV_TIME_BASE_Q, st->time_base);
  if (st->start_time != AV_NOPTS_VALUE) target += st->start_time;
  if (time_us > 0) {
    err = av_seek_frame(w->in, vindex, target, AVSEEK_FLAG_BACKWARD);
    if (err < 0) goto done;
    avcodec_flush_buffers(dec);
  }
  int64_t decoded = 0, eof = 0;
  job_update(w->job, OPX_STATE_RUNNING, -1, -1, INT64_MIN);
  while (!picked) {
    if (cancelled(w)) {
      err = AVERROR_EXIT;
      goto done;
    }
    if (!eof) {
      err = av_read_frame(w->in, pkt);
      if (err == AVERROR_EOF) {
        eof = 1;
        avcodec_send_packet(dec, NULL);
      } else if (err < 0) {
        goto done;
      } else {
        if (pkt->stream_index == vindex) avcodec_send_packet(dec, pkt);
        av_packet_unref(pkt);
      }
    }
    for (;;) {
      err = avcodec_receive_frame(dec, frame);
      if (err == AVERROR(EAGAIN)) break;
      if (err == AVERROR_EOF) {
        err = AVERROR_STREAM_NOT_FOUND;  // nothing decodable at that time
        goto done;
      }
      if (err < 0) goto done;
      decoded++;
      int64_t pts = frame->best_effort_timestamp;
      // Bounded decode budget after the seek point.
      if (pts == AV_NOPTS_VALUE || pts >= target || decoded > 600 || eof) {
        picked = av_frame_clone(frame);
        av_frame_unref(frame);
        if (!picked) err = AVERROR(ENOMEM);
        break;
      }
      av_frame_unref(frame);
    }
    if (!picked && err < 0 && err != AVERROR(EAGAIN)) goto done;
  }
  job_update(w->job, OPX_STATE_FINALIZING, -1, -1, INT64_MIN);
  int rotation = ((int)(stream_rotation(st) + 45) / 90 * 90) % 360;
  int sw, sh;
  fit_box(picked->width, picked->height, max_long, max_short, &sw, &sh);
  int stride = sw * 3;
  rgb = av_malloc((size_t)stride * sh);
  sws = sws_getContext(picked->width, picked->height,
                       (enum AVPixelFormat)picked->format, sw, sh,
                       AV_PIX_FMT_RGB24, SWS_BICUBIC, NULL, NULL, NULL);
  if (!rgb || !sws) {
    err = AVERROR(ENOMEM);
    goto done;
  }
  uint8_t *dst_planes[4] = {rgb};
  int dst_strides[4] = {stride};
  sws_scale(sws, (const uint8_t *const *)picked->data, picked->linesize, 0,
            picked->height, dst_planes, dst_strides);
  int fw = sw, fh = sh;
  const uint8_t *img = rgb;
  if (rotation) {
    rotated = rotate_rgb(rgb, sw, sh, stride, rotation, &fw, &fh);
    if (!rotated) {
      err = AVERROR(ENOMEM);
      goto done;
    }
    img = rotated;
    stride = fw * 3;
  }
  int png = strcmp(codec_name, "png") == 0;
  const AVCodec *codec = avcodec_find_encoder_by_name(codec_name);
  if (!codec) {
    err = AVERROR_ENCODER_NOT_FOUND;
    goto done;
  }
  enc = avcodec_alloc_context3(codec);
  yuv = av_frame_alloc();
  if (!enc || !yuv) {
    err = AVERROR(ENOMEM);
    goto done;
  }
  enc->width = fw;
  enc->height = fh;
  enc->time_base = (AVRational){1, 25};
  enc->pix_fmt = png ? AV_PIX_FMT_RGB24 : AV_PIX_FMT_YUVJ420P;
  if (!png) {
    enc->flags |= AV_CODEC_FLAG_QSCALE;
    enc->global_quality = FF_QP2LAMBDA * (quality < 2 ? 2 : quality > 20 ? 20 : quality);
  }
  err = avcodec_open2(enc, codec, NULL);
  if (err < 0) goto done;
  yuv->format = enc->pix_fmt;
  yuv->width = fw;
  yuv->height = fh;
  err = av_frame_get_buffer(yuv, 0);
  if (err < 0) goto done;
  if (png) {
    for (int y = 0; y < fh; y++)
      memcpy(yuv->data[0] + (size_t)y * yuv->linesize[0],
             img + (size_t)y * stride, (size_t)fw * 3);
  } else {
    sws_freeContext(sws);
    sws = sws_getContext(fw, fh, AV_PIX_FMT_RGB24, fw, fh, AV_PIX_FMT_YUVJ420P,
                         SWS_BICUBIC, NULL, NULL, NULL);
    if (!sws) {
      err = AVERROR(ENOMEM);
      goto done;
    }
    const uint8_t *src_planes[4] = {img};
    int src_strides[4] = {stride};
    sws_scale(sws, src_planes, src_strides, 0, fh, yuv->data, yuv->linesize);
  }
  yuv->pts = 0;
  err = avcodec_send_frame(enc, yuv);
  if (err >= 0) err = avcodec_send_frame(enc, NULL);
  if (err < 0) goto done;
  err = avcodec_receive_packet(enc, pkt);
  if (err < 0) goto done;
  err = write_file(w->output, pkt->data, pkt->size);
  av_packet_unref(pkt);
done:
  av_free(rgb);
  av_free(rotated);
  sws_freeContext(sws);
  av_frame_free(&yuv);
  av_frame_free(&picked);
  av_frame_free(&frame);
  av_packet_free(&pkt);
  avcodec_free_context(&enc);
  avcodec_free_context(&dec);
  return err;
}

// -------------------------------------------------- job: remux / transcode

enum { MODE_NONE = 0, MODE_COPY = 1, MODE_ENCODE = 2 };

typedef struct {
  int in_index, out_index, mode;
  enum AVMediaType type;
  AVCodecContext *dec, *enc;
  struct SwsContext *sws;
  SwrContext *swr;
  AVAudioFifo *fifo;
  AVFrame *frame, *scaled;
  int64_t next_pts, last_pts;
  int64_t first_dts;  // copy: offset applied to output timestamps
} track;

static int read_mode(const char *plan, const char *key) {
  char v[16];
  if (!json_str(plan, key, v, sizeof v)) return MODE_NONE;
  if (!strcmp(v, "copy")) return MODE_COPY;
  if (!strcmp(v, "encode")) return MODE_ENCODE;
  return MODE_NONE;
}

static int setup_video_encoder(worker *w, track *t, AVStream *ist,
                               AVStream *ost) {
  char name[32] = "mpeg4";
  json_str(w->plan, "video_codec", name, sizeof name);
  const AVCodec *codec = avcodec_find_encoder_by_name(name);
  if (!codec || codec->type != AVMEDIA_TYPE_VIDEO)
    return AVERROR_ENCODER_NOT_FOUND;
  int err = 0;
  t->dec = open_decoder(ist, 4, &err);
  if (!t->dec) return err;
  int ow, oh;
  fit_box(t->dec->width, t->dec->height,
          (int)json_i64(w->plan, "max_long", 0),
          (int)json_i64(w->plan, "max_short", 0), &ow, &oh);
  AVCodecContext *enc = t->enc = avcodec_alloc_context3(codec);
  if (!enc) return AVERROR(ENOMEM);
  AVRational fr = av_guess_frame_rate(w->in, ist, NULL);
  if (fr.num <= 0 || fr.den <= 0 || av_q2d(fr) > 120) fr = (AVRational){25, 1};
  // Rate-based time base: keeps encoders with 16-bit limits happy; the
  // monotonic guard below handles variable-rate inputs.
  av_reduce(&fr.num, &fr.den, fr.num, fr.den, 65535);
  enc->width = ow;
  enc->height = oh;
  enc->framerate = fr;
  enc->time_base = av_inv_q(fr);
  enc->sample_aspect_ratio = t->dec->sample_aspect_ratio;
  enc->pix_fmt = AV_PIX_FMT_YUV420P;
  enc->bit_rate = json_i64(w->plan, "video_bitrate", 2500000);
  enc->gop_size = (int)(av_q2d(fr) * 2 + 0.5);
  enc->max_b_frames = 0;
  enc->thread_count = 4;
  enc->color_primaries = t->dec->color_primaries;
  enc->color_trc = t->dec->color_trc;
  enc->colorspace = t->dec->colorspace;
  enc->color_range = AVCOL_RANGE_MPEG;
  if (w->out->oformat->flags & AVFMT_GLOBALHEADER)
    enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  err = avcodec_open2(enc, codec, NULL);
  if (err < 0) return err == AVERROR(EINVAL) ? AVERROR_ENCODER_NOT_FOUND : err;
  err = avcodec_parameters_from_context(ost->codecpar, enc);
  if (err < 0) return err;
  ost->time_base = enc->time_base;
  ost->avg_frame_rate = fr;
  // Keep orientation as container metadata instead of re-rotating pixels.
  const AVPacketSideData *sd = av_packet_side_data_get(
      ist->codecpar->coded_side_data, ist->codecpar->nb_coded_side_data,
      AV_PKT_DATA_DISPLAYMATRIX);
  if (sd) {
    AVPacketSideData *copy = av_packet_side_data_new(
        &ost->codecpar->coded_side_data, &ost->codecpar->nb_coded_side_data,
        AV_PKT_DATA_DISPLAYMATRIX, sd->size, 0);
    if (copy) memcpy(copy->data, sd->data, sd->size);
  }
  t->scaled = av_frame_alloc();
  t->frame = av_frame_alloc();
  if (!t->scaled || !t->frame) return AVERROR(ENOMEM);
  t->scaled->format = enc->pix_fmt;
  t->scaled->width = ow;
  t->scaled->height = oh;
  err = av_frame_get_buffer(t->scaled, 0);
  t->last_pts = AV_NOPTS_VALUE;
  return err;
}

static int setup_audio_encoder(worker *w, track *t, AVStream *ist,
                               AVStream *ost) {
  char name[32] = "aac";
  json_str(w->plan, "audio_codec", name, sizeof name);
  const AVCodec *codec = avcodec_find_encoder_by_name(name);
  if (!codec || codec->type != AVMEDIA_TYPE_AUDIO)
    return AVERROR_ENCODER_NOT_FOUND;
  int err = 0;
  t->dec = open_decoder(ist, 1, &err);
  if (!t->dec) return err;
  AVCodecContext *enc = t->enc = avcodec_alloc_context3(codec);
  if (!enc) return AVERROR(ENOMEM);
  int rate = (int)json_i64(w->plan, "sample_rate", 0);
  if (rate <= 0) rate = t->dec->sample_rate > 0 ? t->dec->sample_rate : 48000;
  if (rate > 48000) rate = 48000;
  int channels = (int)json_i64(w->plan, "channels", 2);
  if (channels <= 0 || channels > t->dec->ch_layout.nb_channels)
    channels = t->dec->ch_layout.nb_channels;
  if (channels > 2) channels = 2;
  if (channels <= 0) channels = 2;
  av_channel_layout_default(&enc->ch_layout, channels);
  enc->sample_rate = rate;
  const enum AVSampleFormat *fmts = NULL;
  int nfmts = 0;
  avcodec_get_supported_config(NULL, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0,
                               (const void **)&fmts, &nfmts);
  enc->sample_fmt = fmts && nfmts > 0 ? fmts[0] : AV_SAMPLE_FMT_FLTP;
  enc->bit_rate = json_i64(w->plan, "audio_bitrate", 128000);
  enc->time_base = (AVRational){1, rate};
  if (w->out->oformat->flags & AVFMT_GLOBALHEADER)
    enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  err = avcodec_open2(enc, codec, NULL);
  if (err < 0) return err;
  err = avcodec_parameters_from_context(ost->codecpar, enc);
  if (err < 0) return err;
  ost->time_base = enc->time_base;
  err = swr_alloc_set_opts2(&t->swr, &enc->ch_layout, enc->sample_fmt, rate,
                            &t->dec->ch_layout, t->dec->sample_fmt,
                            t->dec->sample_rate, 0, NULL);
  if (err < 0) return err;
  err = swr_init(t->swr);
  if (err < 0) return err;
  t->fifo = av_audio_fifo_alloc(enc->sample_fmt, channels,
                                enc->frame_size > 0 ? enc->frame_size : 4096);
  t->frame = av_frame_alloc();
  if (!t->fifo || !t->frame) return AVERROR(ENOMEM);
  return 0;
}

static int write_encoded(worker *w, track *t) {
  AVPacket *pkt = av_packet_alloc();
  if (!pkt) return AVERROR(ENOMEM);
  int err;
  for (;;) {
    err = avcodec_receive_packet(t->enc, pkt);
    if (err == AVERROR(EAGAIN) || err == AVERROR_EOF) {
      err = 0;
      break;
    }
    if (err < 0) break;
    pkt->stream_index = t->out_index;
    av_packet_rescale_ts(pkt, t->enc->time_base,
                         w->out->streams[t->out_index]->time_base);
    err = av_interleaved_write_frame(w->out, pkt);
    if (err < 0) break;
  }
  av_packet_free(&pkt);
  return err;
}

static int encode_video_frame(worker *w, track *t, AVFrame *in) {
  int err;
  if (!in) {
    err = avcodec_send_frame(t->enc, NULL);
    return err < 0 && err != AVERROR_EOF ? err : write_encoded(w, t);
  }
  if (!t->sws) {
    t->sws = sws_getContext(in->width, in->height,
                            (enum AVPixelFormat)in->format, t->scaled->width,
                            t->scaled->height, t->enc->pix_fmt, SWS_BICUBIC,
                            NULL, NULL, NULL);
    if (!t->sws) return AVERROR(ENOMEM);
  }
  err = av_frame_make_writable(t->scaled);
  if (err < 0) return err;
  sws_scale(t->sws, (const uint8_t *const *)in->data, in->linesize, 0,
            in->height, t->scaled->data, t->scaled->linesize);
  AVStream *ist = w->in->streams[t->in_index];
  int64_t ts = in->best_effort_timestamp;
  int64_t pts;
  if (ts == AV_NOPTS_VALUE) {
    pts = t->last_pts == AV_NOPTS_VALUE ? 0 : t->last_pts + 1;
  } else {
    int64_t us = av_rescale_q(ts, ist->time_base, AV_TIME_BASE_Q) -
                 w->start_us;
    pts = av_rescale_q(us, AV_TIME_BASE_Q, t->enc->time_base);
  }
  if (t->last_pts != AV_NOPTS_VALUE && pts <= t->last_pts) {
    // Variable/broken timestamps: drop a frame that would go backwards
    // in the rate-based time base rather than emit invalid output.
    return 0;
  }
  if (pts < 0) return 0;
  t->last_pts = pts;
  t->scaled->pts = pts;
  err = avcodec_send_frame(t->enc, t->scaled);
  if (err < 0) return err;
  return write_encoded(w, t);
}

static int drain_audio_fifo(worker *w, track *t, int flush) {
  int size = t->enc->frame_size > 0 ? t->enc->frame_size : 4096;
  int err = 0;
  while (av_audio_fifo_size(t->fifo) >= size ||
         (flush && av_audio_fifo_size(t->fifo) > 0)) {
    int n = av_audio_fifo_size(t->fifo);
    if (n > size) n = size;
    AVFrame *f = av_frame_alloc();
    if (!f) return AVERROR(ENOMEM);
    f->nb_samples = n;
    f->format = t->enc->sample_fmt;
    f->sample_rate = t->enc->sample_rate;
    av_channel_layout_copy(&f->ch_layout, &t->enc->ch_layout);
    err = av_frame_get_buffer(f, 0);
    if (err >= 0 && av_audio_fifo_read(t->fifo, (void **)f->data, n) < n)
      err = AVERROR(EIO);
    if (err >= 0) {
      f->pts = t->next_pts;
      t->next_pts += n;
      err = avcodec_send_frame(t->enc, f);
    }
    av_frame_free(&f);
    if (err < 0) return err;
    err = write_encoded(w, t);
    if (err < 0) return err;
  }
  if (flush) {
    err = avcodec_send_frame(t->enc, NULL);
    if (err < 0 && err != AVERROR_EOF) return err;
    return write_encoded(w, t);
  }
  return 0;
}

static int encode_audio_frame(worker *w, track *t, AVFrame *in) {
  int out_samples = swr_get_out_samples(t->swr, in ? in->nb_samples : 0);
  if (out_samples > 0) {
    uint8_t **buf = NULL;
    int err = av_samples_alloc_array_and_samples(
        &buf, NULL, t->enc->ch_layout.nb_channels, out_samples,
        t->enc->sample_fmt, 0);
    if (err < 0) return err;
    int n = swr_convert(t->swr, buf, out_samples,
                        in ? (const uint8_t **)in->extended_data : NULL,
                        in ? in->nb_samples : 0);
    if (n > 0 && av_audio_fifo_write(t->fifo, (void **)buf, n) < n) n = -1;
    av_freep(&buf[0]);
    av_freep(&buf);
    if (n < 0) return n == -1 ? AVERROR(ENOMEM) : n;
  }
  return drain_audio_fifo(w, t, in == NULL);
}

// Feeds a packet (or NULL to flush) through decoder → encoder.
static int transcode_packet(worker *w, track *t, AVPacket *pkt, int *past_end) {
  int err = avcodec_send_packet(t->dec, pkt);
  if (err < 0 && err != AVERROR_EOF && err != AVERROR_INVALIDDATA) return err;
  AVStream *ist = w->in->streams[t->in_index];
  for (;;) {
    err = avcodec_receive_frame(t->dec, t->frame);
    if (err == AVERROR(EAGAIN) || err == AVERROR_EOF) return 0;
    if (err == AVERROR_INVALIDDATA) continue;
    if (err < 0) return err;
    int64_t ts = t->frame->best_effort_timestamp;
    int64_t us = ts == AV_NOPTS_VALUE
                     ? AV_NOPTS_VALUE
                     : av_rescale_q(ts, ist->time_base, AV_TIME_BASE_Q);
    if (us != AV_NOPTS_VALUE && us < w->start_us) {
      av_frame_unref(t->frame);
      continue;  // before the requested range
    }
    if (us != AV_NOPTS_VALUE && w->end_us > 0 && us >= w->end_us) {
      av_frame_unref(t->frame);
      *past_end = 1;
      continue;
    }
    if (t->type == AVMEDIA_TYPE_VIDEO) report(w, us);
    err = t->type == AVMEDIA_TYPE_VIDEO ? encode_video_frame(w, t, t->frame)
                                        : encode_audio_frame(w, t, t->frame);
    av_frame_unref(t->frame);
    if (err < 0) return err;
  }
}

static int copy_packet(worker *w, track *t, AVPacket *pkt, int *past_end) {
  AVStream *ist = w->in->streams[t->in_index];
  AVStream *ost = w->out->streams[t->out_index];
  int64_t ts = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
  if (ts != AV_NOPTS_VALUE) {
    int64_t us = av_rescale_q(ts, ist->time_base, AV_TIME_BASE_Q);
    if (w->end_us > 0 && us >= w->end_us) {
      *past_end = 1;
      return 0;
    }
    if (t->type != AVMEDIA_TYPE_SUBTITLE) report(w, us);
  }
  // Never start a copied video track mid-GOP.
  if (t->first_dts == AV_NOPTS_VALUE) {
    if (t->type == AVMEDIA_TYPE_VIDEO && !(pkt->flags & AV_PKT_FLAG_KEY))
      return 0;
    t->first_dts = pkt->dts != AV_NOPTS_VALUE ? pkt->dts : 0;
  }
  // start_us is on the input timeline; the copy starts at the keyframe
  // at/before it, so output begins near zero (small negative offsets are
  // normalized by the muxer).
  int64_t offset = av_rescale_q(w->start_us, AV_TIME_BASE_Q, ist->time_base);
  if (pkt->pts != AV_NOPTS_VALUE) pkt->pts -= offset;
  if (pkt->dts != AV_NOPTS_VALUE) pkt->dts -= offset;
  av_packet_rescale_ts(pkt, ist->time_base, ost->time_base);
  pkt->stream_index = t->out_index;
  pkt->pos = -1;
  return av_interleaved_write_frame(w->out, pkt);
}

static int run_mux(worker *w, int transcode) {
  char format[32];
  if (!json_str(w->plan, "format", format, sizeof format))
    return AVERROR(EINVAL);
  track tracks[3];
  memset(tracks, 0, sizeof tracks);
  const char *keys[3][2] = {{"video_stream", "video_mode"},
                            {"audio_stream", "audio_mode"},
                            {"subtitle_stream", "subtitle_mode"}};
  const enum AVMediaType types[3] = {AVMEDIA_TYPE_VIDEO, AVMEDIA_TYPE_AUDIO,
                                     AVMEDIA_TYPE_SUBTITLE};
  int err = avformat_alloc_output_context2(&w->out, NULL, format, w->output);
  if (err < 0 || !w->out) return err < 0 ? err : AVERROR_MUXER_NOT_FOUND;
  int ntracks = 0;
  for (int i = 0; i < 3; i++) {
    int index = (int)json_i64(w->plan, keys[i][0], -1);
    int mode = read_mode(w->plan, keys[i][1]);
    if (index < 0 || mode == MODE_NONE) continue;
    if (index >= (int)w->in->nb_streams ||
        w->in->streams[index]->codecpar->codec_type != types[i]) {
      err = AVERROR_STREAM_NOT_FOUND;
      goto done;
    }
    if (mode == MODE_ENCODE && (!transcode || i == 2)) {
      err = AVERROR(EINVAL);  // subtitles are never re-encoded here
      goto done;
    }
    AVStream *ist = w->in->streams[index];
    if (mode == MODE_COPY &&
        avformat_query_codec(w->out->oformat, ist->codecpar->codec_id,
                             FF_COMPLIANCE_NORMAL) != 1) {
      err = AVERROR(ENOTSUP);  // reported as preset incompatible
      goto done;
    }
    AVStream *ost = avformat_new_stream(w->out, NULL);
    if (!ost) {
      err = AVERROR(ENOMEM);
      goto done;
    }
    track *t = &tracks[ntracks++];
    t->in_index = index;
    t->out_index = ost->index;
    t->mode = mode;
    t->type = types[i];
    t->first_dts = AV_NOPTS_VALUE;
    av_dict_copy(&ost->metadata, ist->metadata, 0);
    ost->disposition = ist->disposition & ~AV_DISPOSITION_ATTACHED_PIC;
    if (mode == MODE_COPY) {
      err = avcodec_parameters_copy(ost->codecpar, ist->codecpar);
      if (err < 0) goto done;
      ost->codecpar->codec_tag = 0;
      ost->time_base = ist->time_base;
    } else if (types[i] == AVMEDIA_TYPE_VIDEO) {
      err = setup_video_encoder(w, t, ist, ost);
      if (err < 0) goto done;
    } else {
      err = setup_audio_encoder(w, t, ist, ost);
      if (err < 0) goto done;
    }
  }
  if (ntracks == 0) {
    err = AVERROR_STREAM_NOT_FOUND;
    goto done;
  }
  for (unsigned i = 0; i < w->in->nb_streams; i++) {
    int used = 0;
    for (int k = 0; k < ntracks; k++) used |= tracks[k].in_index == (int)i;
    w->in->streams[i]->discard = used ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
  }
  AVDictionary *io_opts = NULL;
  av_dict_set(&io_opts, "protocol_whitelist", "file", 0);
  err = avio_open2(&w->out->pb, w->output, AVIO_FLAG_WRITE,
                   &w->in->interrupt_callback, &io_opts);
  av_dict_free(&io_opts);
  if (err < 0) goto done;
  AVDictionary *mux_opts = NULL;
  if (!strcmp(format, "mp4") || !strcmp(format, "ipod"))
    av_dict_set(&mux_opts, "movflags", "+faststart", 0);
  err = avformat_write_header(w->out, &mux_opts);
  av_dict_free(&mux_opts);
  if (err < 0) goto done;

  if (w->start_us > 0) {
    int64_t seek = w->start_us;
    if (w->in->start_time != AV_NOPTS_VALUE) seek += w->in->start_time;
    err = avformat_seek_file(w->in, -1, INT64_MIN, seek, seek, 0);
    if (err < 0) goto done;
    // Keep absolute timestamps comparable: express start relative to the
    // stream timeline that packets carry.
    if (w->in->start_time != AV_NOPTS_VALUE) {
      w->start_us += w->in->start_time;
      if (w->end_us > 0) w->end_us += w->in->start_time;
    }
  } else if (w->in->start_time != AV_NOPTS_VALUE && w->in->start_time > 0) {
    w->start_us = w->in->start_time;
    if (w->end_us > 0) w->end_us += w->in->start_time;
  }
  job_update(w->job, OPX_STATE_RUNNING, -1, 0, INT64_MIN);
  AVPacket *pkt = av_packet_alloc();
  if (!pkt) {
    err = AVERROR(ENOMEM);
    goto done;
  }
  int ended[3] = {0, 0, 0};
  for (;;) {
    if (cancelled(w)) {
      err = AVERROR_EXIT;
      break;
    }
    err = av_read_frame(w->in, pkt);
    if (err == AVERROR_EOF) {
      err = 0;
      break;
    }
    if (err < 0) break;
    int k = 0;
    while (k < ntracks && tracks[k].in_index != pkt->stream_index) k++;
    track *t = k < ntracks ? &tracks[k] : NULL;
    if (!t || ended[k]) {
      av_packet_unref(pkt);
      continue;
    }
    int past_end = 0;
    err = t->mode == MODE_COPY ? copy_packet(w, t, pkt, &past_end)
                               : transcode_packet(w, t, pkt, &past_end);
    av_packet_unref(pkt);
    if (err < 0) break;
    if (past_end) ended[k] = 1;
    int all = 1;
    for (int m = 0; m < ntracks; m++)
      all &= ended[m] || tracks[m].type == AVMEDIA_TYPE_SUBTITLE;
    if (all) break;
  }
  av_packet_free(&pkt);
  if (err < 0) goto done;
  job_update(w->job, OPX_STATE_FINALIZING, -1, -1, INT64_MIN);
  // Flush decoders, buffered audio and encoders (delayed frames included).
  for (int k = 0; k < ntracks && err >= 0; k++) {
    track *t = &tracks[k];
    if (t->mode != MODE_ENCODE) continue;
    int past_end = 0;
    err = transcode_packet(w, t, NULL, &past_end);
    if (err >= 0)
      err = t->type == AVMEDIA_TYPE_VIDEO ? encode_video_frame(w, t, NULL)
                                          : encode_audio_frame(w, t, NULL);
  }
  if (err >= 0 && cancelled(w)) err = AVERROR_EXIT;
  if (err >= 0) err = av_write_trailer(w->out);
done:
  for (int k = 0; k < 3; k++) {
    avcodec_free_context(&tracks[k].dec);
    avcodec_free_context(&tracks[k].enc);
    sws_freeContext(tracks[k].sws);
    swr_free(&tracks[k].swr);
    if (tracks[k].fifo) av_audio_fifo_free(tracks[k].fifo);
    av_frame_free(&tracks[k].frame);
    av_frame_free(&tracks[k].scaled);
  }
  if (w->out) {
    if (w->out->pb) avio_closep(&w->out->pb);
    avformat_free_context(w->out);
    w->out = NULL;
  }
  return err;
}

static int error_code(int err, worker *w) {
  if (err == AVERROR(ENOTSUP) || err == AVERROR_STREAM_NOT_FOUND)
    return OPX_E_PRESET_INCOMPATIBLE;
  if (err == AVERROR(EINVAL)) return OPX_E_INVALID_ARGUMENT;
  return map_av_error(err, &w->guard, &w->job->cancel);
}

#if defined(_WIN32)
static DWORD WINAPI job_main(LPVOID arg)
#else
static void *job_main(void *arg)
#endif
{
  opx_media_job *job = arg;
  worker w;
  memset(&w, 0, sizeof w);
  w.job = job;
  w.plan = job->plan;
  w.guard.cancel = &job->cancel;
  int64_t timeout = json_i64(job->plan, "timeout_ms", 0);
  if (timeout > 0) w.guard.deadline = av_gettime_relative() + timeout * 1000;
  char op[32], input[OPX_MAX_TEXT];
  json_str(job->plan, "operation", op, sizeof op);
  json_str(job->plan, "input", input, sizeof input);
  json_str(job->plan, "output", w.output, sizeof w.output);
  w.start_us = json_i64(job->plan, "start_us", 0);
  w.end_us = json_i64(job->plan, "end_us", 0);
  if (w.start_us < 0) w.start_us = 0;
  job_update(job, OPX_STATE_PREPARING, -1, 0, INT64_MIN);
  int err = open_input(input, &w.guard, &w.in);
  if (err >= 0) {
    if (strcmp(op, "snapshot") != 0) {
      int64_t dur = w.in->duration > 0 ? w.in->duration : 0;
      int64_t end = w.end_us > 0 && (dur == 0 || w.end_us < dur) ? w.end_us
                                                                  : dur;
      w.total_us = end > w.start_us ? end - w.start_us : 0;
      job_update(job, -1, -1, 0, w.total_us);
    }
    err = strcmp(op, "snapshot") == 0 ? run_snapshot(&w)
                                      : run_mux(&w, !strcmp(op, "transcode"));
  }
  if (w.in) avformat_close_input(&w.in);
  if (err < 0) {
    unlink_file(w.output);  // never leave a partial file looking complete
    int code = error_code(err, &w);
    job_update(job, code == OPX_E_CANCELLED ? OPX_STATE_CANCELLED
                                            : OPX_STATE_FAILED,
               code, -1, INT64_MIN);
  } else {
    job_update(job, OPX_STATE_SUCCEEDED, OPX_OK, w.total_us, INT64_MIN);
  }
  return 0;
}

int32_t opx_media_job_start(opx_media_job *job) {
  if (!job) return OPX_E_INVALID_ARGUMENT;
  if (job->started) return OPX_E_BAD_STATE;
  global_init();
  job->started = 1;
#if defined(_WIN32)
  job->thread = CreateThread(NULL, 0, job_main, job, 0, NULL);
  if (!job->thread) {
#else
  if (pthread_create(&job->thread, NULL, job_main, job) != 0) {
#endif
    job->started = 0;
    return OPX_E_NATIVE_FAILURE;
  }
  return OPX_OK;
}

int32_t opx_media_job_join(opx_media_job *job) {
  if (!job) return OPX_E_INVALID_ARGUMENT;
  if (!job->started) return OPX_E_BAD_STATE;
  if (job->joined) return OPX_OK;
#if defined(_WIN32)
  WaitForSingleObject(job->thread, INFINITE);
  CloseHandle(job->thread);
#else
  pthread_join(job->thread, NULL);
#endif
  job->joined = 1;
  return OPX_OK;
}

void opx_media_job_destroy(opx_media_job *job) {
  if (!job) return;
  if (job->started && !job->joined) return;  // still running: refuse to free
  mutex_destroy(&job->lock);
  free(job->plan);
  free(job);
}

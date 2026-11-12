// A thin C layer over Wuffs for src/wuffs.zig. It never allocates: the decoder
// state lives in caller memory of nanoview_wuffs_state_size() bytes, and the
// pixel and work buffers are passed in on every call. Compiling it needs only
// vendor/wuffs on the include path; the configuration is below.

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__STATIC_FUNCTIONS
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__ADLER32
#define WUFFS_CONFIG__MODULE__BMP
#define WUFFS_CONFIG__MODULE__CRC32
#define WUFFS_CONFIG__MODULE__DEFLATE
#define WUFFS_CONFIG__MODULE__GIF
#define WUFFS_CONFIG__MODULE__LZW
#define WUFFS_CONFIG__MODULE__PNG
#define WUFFS_CONFIG__MODULE__QOI
#define WUFFS_CONFIG__MODULE__TARGA
#define WUFFS_CONFIG__MODULE__ZLIB
#define WUFFS_CONFIG__DST_PIXEL_FORMAT__ENABLE_ALLOWLIST
#define WUFFS_CONFIG__DST_PIXEL_FORMAT__ALLOW_BGRA_PREMUL

#include "wuffs-v0.4.c"

// Results shared with src/wuffs.zig (`Status` there).
enum {
  NANOVIEW_WUFFS_OK = 0,
  NANOVIEW_WUFFS_END = 1,
  NANOVIEW_WUFFS_UNSUPPORTED = 2,
  NANOVIEW_WUFFS_CORRUPT = 3,
  NANOVIEW_WUFFS_TRUNCATED = 4,
  NANOVIEW_WUFFS_WORK_TOO_SMALL = 5,
  NANOVIEW_WUFFS_OUTPUT_TOO_SMALL = 6,
};

// Mirrors `BridgeInfo` in src/wuffs.zig.
typedef struct {
  uint32_t width;
  uint32_t height;
  uint32_t fourcc;
  uint32_t loop_count;
  uint64_t work_len;
} nanoview_wuffs_info;

// Mirrors `BridgeFrame` in src/wuffs.zig.
typedef struct {
  uint32_t x0;
  uint32_t y0;
  uint32_t x1;
  uint32_t y1;
  uint64_t duration_flicks;
  uint64_t index;
  uint32_t background_bgra;
  uint8_t disposal;
  uint8_t overwrite;
  uint8_t padding[2];
} nanoview_wuffs_frame;

typedef struct {
  union {
    wuffs_bmp__decoder bmp;
    wuffs_gif__decoder gif;
    wuffs_png__decoder png;
    wuffs_qoi__decoder qoi;
    wuffs_targa__decoder targa;
  } decoder;
  wuffs_base__image_config image_config;
  wuffs_base__io_buffer source;
  wuffs_base__pixel_buffer pixels;
  uint64_t first_frame_position;
} nanoview_wuffs_state;

size_t nanoview_wuffs_state_size(void) { return sizeof(nanoview_wuffs_state); }

size_t nanoview_wuffs_state_align(void) { return _Alignof(nanoview_wuffs_state); }

static wuffs_base__image_decoder* decoder_of(nanoview_wuffs_state* state) {
  return (wuffs_base__image_decoder*)(&state->decoder);
}

static int32_t status_code(wuffs_base__status status) {
  if (status.repr == NULL) {
    return NANOVIEW_WUFFS_OK;
  }
  if (status.repr == wuffs_base__note__end_of_data) {
    return NANOVIEW_WUFFS_END;
  }
  // The source is always closed, so any suspension means the data stopped early.
  if (wuffs_base__status__is_suspension(&status)) {
    return NANOVIEW_WUFFS_TRUNCATED;
  }
  if (status.repr == wuffs_base__error__bad_workbuf_length) {
    return NANOVIEW_WUFFS_WORK_TOO_SMALL;
  }
  // Every Wuffs module names its cut-off-data error "#<module>: truncated input".
  if (strstr(status.repr, ": truncated input") != NULL) {
    return NANOVIEW_WUFFS_TRUNCATED;
  }
  if (strstr(status.repr, "unsupported") != NULL) {
    return NANOVIEW_WUFFS_UNSUPPORTED;
  }
  return NANOVIEW_WUFFS_CORRUPT;
}

static wuffs_base__status initialize(nanoview_wuffs_state* state, int32_t fourcc) {
  uint32_t const options = WUFFS_INITIALIZE__ALREADY_ZEROED;
  switch (fourcc) {
    case WUFFS_BASE__FOURCC__BMP:
      return wuffs_bmp__decoder__initialize(&state->decoder.bmp,
                                            sizeof(state->decoder.bmp),
                                            WUFFS_VERSION, options);
    case WUFFS_BASE__FOURCC__GIF:
      return wuffs_gif__decoder__initialize(&state->decoder.gif,
                                            sizeof(state->decoder.gif),
                                            WUFFS_VERSION, options);
    case WUFFS_BASE__FOURCC__PNG:
      return wuffs_png__decoder__initialize(&state->decoder.png,
                                            sizeof(state->decoder.png),
                                            WUFFS_VERSION, options);
    case WUFFS_BASE__FOURCC__QOI:
      return wuffs_qoi__decoder__initialize(&state->decoder.qoi,
                                            sizeof(state->decoder.qoi),
                                            WUFFS_VERSION, options);
    case WUFFS_BASE__FOURCC__TGA:
      return wuffs_targa__decoder__initialize(&state->decoder.targa,
                                              sizeof(state->decoder.targa),
                                              WUFFS_VERSION, options);
    default:
      return wuffs_base__make_status(wuffs_base__error__unsupported_option);
  }
}

// Reads the image header. `bytes` must stay unchanged while the state is used.
int32_t nanoview_wuffs_open(void* opaque, const uint8_t* bytes, size_t len,
                            nanoview_wuffs_info* info) {
  nanoview_wuffs_state* state = (nanoview_wuffs_state*)opaque;
  memset(state, 0, sizeof(*state));
  memset(info, 0, sizeof(*info));
  // Wuffs readers take a mutable pointer but never write through it.
  uint8_t* data = (uint8_t*)bytes;
  int32_t fourcc =
      wuffs_base__magic_number_guess_fourcc(wuffs_base__make_slice_u8(data, len), true);
  if (fourcc <= 0) {
    return NANOVIEW_WUFFS_UNSUPPORTED;
  }
  wuffs_base__status status = initialize(state, fourcc);
  if (status.repr != NULL) {
    return NANOVIEW_WUFFS_UNSUPPORTED;
  }
  state->source = wuffs_base__ptr_u8__reader(data, len, true);
  wuffs_base__image_decoder* decoder = decoder_of(state);
  status = wuffs_base__image_decoder__decode_image_config(decoder, &state->image_config,
                                                          &state->source);
  int32_t code = status_code(status);
  if (code != NANOVIEW_WUFFS_OK) {
    return code == NANOVIEW_WUFFS_END ? NANOVIEW_WUFFS_CORRUPT : code;
  }
  if (!wuffs_base__image_config__is_valid(&state->image_config)) {
    return NANOVIEW_WUFFS_CORRUPT;
  }
  uint32_t width = wuffs_base__pixel_config__width(&state->image_config.pixcfg);
  uint32_t height = wuffs_base__pixel_config__height(&state->image_config.pixcfg);
  wuffs_base__pixel_config__set(&state->image_config.pixcfg,
                                WUFFS_BASE__PIXEL_FORMAT__BGRA_PREMUL,
                                WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, width, height);
  state->first_frame_position =
      wuffs_base__image_config__first_frame_io_position(&state->image_config);
  info->width = width;
  info->height = height;
  info->fourcc = (uint32_t)fourcc;
  info->loop_count = wuffs_base__image_decoder__num_animation_loops(decoder);
  info->work_len = wuffs_base__image_decoder__workbuf_len(decoder).max_incl;
  return NANOVIEW_WUFFS_OK;
}

// Reads the header into a stack state, for callers without decoder memory.
int32_t nanoview_wuffs_probe(const uint8_t* bytes, size_t len, nanoview_wuffs_info* info) {
  nanoview_wuffs_state state;
  return nanoview_wuffs_open(&state, bytes, len, info);
}

int32_t nanoview_wuffs_frame_config(void* opaque, nanoview_wuffs_frame* frame) {
  nanoview_wuffs_state* state = (nanoview_wuffs_state*)opaque;
  memset(frame, 0, sizeof(*frame));
  wuffs_base__frame_config config;
  memset(&config, 0, sizeof(config));
  wuffs_base__status status = wuffs_base__image_decoder__decode_frame_config(
      decoder_of(state), &config, &state->source);
  int32_t code = status_code(status);
  if (code != NANOVIEW_WUFFS_OK) {
    return code;
  }
  wuffs_base__rect_ie_u32 bounds = wuffs_base__frame_config__bounds(&config);
  frame->x0 = bounds.min_incl_x;
  frame->y0 = bounds.min_incl_y;
  frame->x1 = bounds.max_excl_x;
  frame->y1 = bounds.max_excl_y;
  frame->duration_flicks = (uint64_t)wuffs_base__frame_config__duration(&config);
  frame->index = wuffs_base__frame_config__index(&config);
  frame->background_bgra = wuffs_base__frame_config__background_color(&config);
  frame->disposal = wuffs_base__frame_config__disposal(&config);
  frame->overwrite = wuffs_base__frame_config__overwrite_instead_of_blend(&config) ? 1 : 0;
  return NANOVIEW_WUFFS_OK;
}

// Decodes the frame whose config was just read onto `canvas`, a tightly packed
// width * height premultiplied BGRA picture.
int32_t nanoview_wuffs_decode_frame(void* opaque, uint8_t* canvas, size_t canvas_len,
                                    uint8_t* work, size_t work_len, uint8_t overwrite) {
  nanoview_wuffs_state* state = (nanoview_wuffs_state*)opaque;
  wuffs_base__status status = wuffs_base__pixel_buffer__set_from_slice(
      &state->pixels, &state->image_config.pixcfg,
      wuffs_base__make_slice_u8(canvas, canvas_len));
  if (status.repr != NULL) {
    return NANOVIEW_WUFFS_OUTPUT_TOO_SMALL;
  }
  wuffs_base__pixel_blend blend =
      overwrite ? WUFFS_BASE__PIXEL_BLEND__SRC : WUFFS_BASE__PIXEL_BLEND__SRC_OVER;
  status = wuffs_base__image_decoder__decode_frame(
      decoder_of(state), &state->pixels, &state->source, blend,
      wuffs_base__make_slice_u8(work, work_len), NULL);
  int32_t code = status_code(status);
  return code == NANOVIEW_WUFFS_END ? NANOVIEW_WUFFS_TRUNCATED : code;
}

// Rewinds to just before the first frame config.
int32_t nanoview_wuffs_restart(void* opaque) {
  nanoview_wuffs_state* state = (nanoview_wuffs_state*)opaque;
  if (state->first_frame_position > state->source.meta.wi) {
    return NANOVIEW_WUFFS_CORRUPT;
  }
  wuffs_base__status status = wuffs_base__image_decoder__restart_frame(
      decoder_of(state), 0, state->first_frame_position);
  if (status.repr != NULL) {
    return status_code(status);
  }
  // The reader's position is pos + ri, and pos is 0 for a whole-file reader.
  state->source.meta.ri = (size_t)state->first_frame_position;
  return NANOVIEW_WUFFS_OK;
}

uint32_t nanoview_wuffs_loop_count(void* opaque) {
  nanoview_wuffs_state* state = (nanoview_wuffs_state*)opaque;
  return wuffs_base__image_decoder__num_animation_loops(decoder_of(state));
}

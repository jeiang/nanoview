// Flat entry points over libwebp for src/webp.zig. libwebp's public structs
// and inline wrappers (WebPDecoderConfig, WebPGetFeatures, WebPDemux) are
// awkward to mirror by hand in Zig, so this file keeps every libwebp type on
// the C side and hands Zig only fixed-width integers and plain pointers.

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "src/webp/decode.h"
#include "src/webp/demux.h"

// Status values shared with src/webp.zig; the first eight are VP8StatusCode.
enum {
  nv_webp_truncated = VP8_STATUS_NOT_ENOUGH_DATA,
  nv_webp_malformed = VP8_STATUS_BITSTREAM_ERROR,
};

typedef struct nv_webp_features {
  uint32_t width;
  uint32_t height;
  uint32_t has_alpha;
  uint32_t has_animation;
} nv_webp_features;

typedef struct nv_webp_canvas {
  uint32_t width;
  uint32_t height;
  uint32_t frame_count;
  uint32_t loop_count;
} nv_webp_canvas;

typedef struct nv_webp_frame {
  const uint8_t* data;
  size_t size;
  uint32_t x;
  uint32_t y;
  uint32_t width;
  uint32_t height;
  uint32_t duration_ms;
  uint32_t dispose_background;
  uint32_t blend;
  uint32_t has_alpha;
} nv_webp_frame;

int nv_webp_get_features(const uint8_t* data, size_t size,
                         nv_webp_features* out) {
  WebPBitstreamFeatures features;
  VP8StatusCode status = WebPGetFeatures(data, size, &features);
  if (status != VP8_STATUS_OK) return (int)status;
  if (features.width <= 0 || features.height <= 0) return nv_webp_malformed;
  out->width = (uint32_t)features.width;
  out->height = (uint32_t)features.height;
  out->has_alpha = features.has_alpha != 0;
  out->has_animation = features.has_animation != 0;
  return VP8_STATUS_OK;
}

// Decodes one still bitstream as premultiplied BGRA straight into 'out', whose
// rows are 'stride' bytes apart. libwebp checks that the image fits 'size'.
int nv_webp_decode_bgra(const uint8_t* data, size_t size, uint8_t* out,
                        size_t out_size, uint32_t stride, uint32_t width,
                        uint32_t height) {
  WebPDecoderConfig config;
  VP8StatusCode status;
  if (!WebPInitDecoderConfig(&config)) return VP8_STATUS_INVALID_PARAM;
  status = WebPGetFeatures(data, size, &config.input);
  if (status != VP8_STATUS_OK) return (int)status;
  if ((uint32_t)config.input.width != width ||
      (uint32_t)config.input.height != height) {
    return nv_webp_malformed;
  }
  config.options.use_threads = 0;
  config.output.colorspace = MODE_bgrA;
  config.output.is_external_memory = 1;
  config.output.u.RGBA.rgba = out;
  config.output.u.RGBA.stride = (int)stride;
  config.output.u.RGBA.size = out_size;
  status = WebPDecode(data, size, &config);
  WebPFreeDecBuffer(&config.output);
  return (int)status;
}

// Parses the whole container. A partial parse tells a cut-off file apart from
// a broken one; only a completely parsed file is handed back.
int nv_webp_demux_new(const uint8_t* data, size_t size, void** out) {
  WebPData webp_data;
  WebPDemuxState state;
  WebPDemuxer* demux;
  webp_data.bytes = data;
  webp_data.size = size;
  demux = WebPDemuxPartial(&webp_data, &state);
  if (demux != NULL && state == WEBP_DEMUX_DONE) {
    *out = demux;
    return VP8_STATUS_OK;
  }
  WebPDemuxDelete(demux);
  if (state == WEBP_DEMUX_PARSE_ERROR) return nv_webp_malformed;
  return nv_webp_truncated;
}

void nv_webp_demux_delete(void* demux) { WebPDemuxDelete((WebPDemuxer*)demux); }

void nv_webp_demux_canvas(const void* demux, nv_webp_canvas* out) {
  const WebPDemuxer* d = (const WebPDemuxer*)demux;
  out->width = WebPDemuxGetI(d, WEBP_FF_CANVAS_WIDTH);
  out->height = WebPDemuxGetI(d, WEBP_FF_CANVAS_HEIGHT);
  out->frame_count = WebPDemuxGetI(d, WEBP_FF_FRAME_COUNT);
  out->loop_count = WebPDemuxGetI(d, WEBP_FF_LOOP_COUNT);
}

// 'number' counts from 1, as in WebPDemuxGetFrame.
int nv_webp_demux_frame(const void* demux, uint32_t number,
                        nv_webp_frame* out) {
  WebPIterator iter;
  int ok;
  if (number == 0 || number > (uint32_t)INT32_MAX) return VP8_STATUS_INVALID_PARAM;
  if (!WebPDemuxGetFrame((const WebPDemuxer*)demux, (int)number, &iter)) {
    return nv_webp_malformed;
  }
  ok = iter.complete && iter.x_offset >= 0 && iter.y_offset >= 0 &&
       iter.width > 0 && iter.height > 0 && iter.duration >= 0;
  if (ok) {
    out->data = iter.fragment.bytes;
    out->size = iter.fragment.size;
    out->x = (uint32_t)iter.x_offset;
    out->y = (uint32_t)iter.y_offset;
    out->width = (uint32_t)iter.width;
    out->height = (uint32_t)iter.height;
    out->duration_ms = (uint32_t)iter.duration;
    out->dispose_background = iter.dispose_method == WEBP_MUX_DISPOSE_BACKGROUND;
    out->blend = iter.blend_method == WEBP_MUX_BLEND;
    out->has_alpha = iter.has_alpha != 0;
  }
  WebPDemuxReleaseIterator(&iter);
  return ok ? VP8_STATUS_OK : nv_webp_malformed;
}

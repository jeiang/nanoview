/* nanoview's stand-in for the configure-generated header (not upstream).
 * Built with -DHAVE_CONFIG_H, src/dsp/cpu.h only enables SIMD when a
 * WEBP_HAVE_* macro is set here; none is, so every target uses the portable C
 * DSP code and no SSE/NEON/MIPS sources are needed. No WEBP_USE_THREAD, so
 * decoding stays on the calling thread. */
#ifndef WEBP_WEBP_CONFIG_H_
#define WEBP_WEBP_CONFIG_H_

#if defined(__GNUC__) || defined(__clang__)
#define HAVE_BUILTIN_BSWAP16 1
#define HAVE_BUILTIN_BSWAP32 1
#define HAVE_BUILTIN_BSWAP64 1
#endif

#endif /* WEBP_WEBP_CONFIG_H_ */

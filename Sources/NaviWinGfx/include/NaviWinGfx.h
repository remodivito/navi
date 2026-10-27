// A thin C face over DirectComposition, Direct3D 11 and Direct2D for the
// Windows shell. Their headers are C++ only, so Swift calls this instead.
// Every function runs on the thread that called nw_init.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NWSurface NWSurface;
typedef struct { float r, g, b, a; } NWColor;   // straight (not premultiplied) alpha

/// Creates the shared D3D11, D2D and DirectComposition devices. 0 on success, else the HRESULT.
int32_t nw_init(void);

/// A composition swap chain filling `hwnd`'s client area, `w` by `h` pixels. NULL on failure.
NWSurface *nw_surface_create(void *hwnd, int32_t w, int32_t h);
int32_t nw_surface_resize(NWSurface *s, int32_t w, int32_t h);
void nw_surface_destroy(NWSurface *s);

/// Starts a frame and clears it to transparent.
void nw_begin(NWSurface *s);
/// A radial gradient disc: `stops` positions 0...1 with matching colours (up to 8).
void nw_glow(NWSurface *s, float x, float y, float radius, const float *stops, const NWColor *colours, int32_t count);
void nw_disc(NWSurface *s, float x, float y, float radius, NWColor c);
/// An open polyline with round caps and joins. `xy` holds `count` x, y pairs.
void nw_polyline(NWSurface *s, const float *xy, int32_t count, float width, NWColor c);
/// A closed, filled polygon.
void nw_fill_polygon(NWSurface *s, const float *xy, int32_t count, NWColor c);
/// Ends the frame and presents it without waiting. 0 on success, else the HRESULT.
int32_t nw_end(NWSurface *s);

/// Blocks until the compositor's next frame (DCompositionWaitForCompositorClock,
/// or DwmFlush where that's missing). Returns 1 if the compositor clock was used.
int32_t nw_wait_frame(void);
/// The compositor's refresh period in seconds, or 0 if unknown.
double nw_refresh_period(void);
/// A high-resolution clock in seconds.
double nw_now(void);

#ifdef __cplusplus
}
#endif

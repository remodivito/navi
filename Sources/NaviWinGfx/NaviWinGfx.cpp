#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_3.h>
#include <d2d1_1.h>
#include <dcomp.h>
#include <dwmapi.h>
#include "NaviWinGfx.h"

template <class T> static void release(T *&p) { if (p) { p->Release(); p = nullptr; } }

static ID3D11Device *d3d;
static IDXGIDevice *dxgiDevice;
static IDXGIFactory2 *factory;
static ID2D1Factory1 *d2dFactory;
static ID2D1Device *d2dDevice;
static IDCompositionDevice *dcomp;
static ID2D1StrokeStyle *roundStroke;

struct NWSurface {
    HWND hwnd;
    IDXGISwapChain1 *chain = nullptr;
    ID2D1DeviceContext *dc = nullptr;
    ID2D1Bitmap1 *target = nullptr;
    ID2D1SolidColorBrush *brush = nullptr;
    IDCompositionTarget *compTarget = nullptr;
    IDCompositionVisual *visual = nullptr;
};

static D2D1_COLOR_F colour(NWColor c) { return D2D1::ColorF(c.r, c.g, c.b, c.a); }

extern "C" int32_t nw_init(void) {
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                   nullptr, 0, D3D11_SDK_VERSION, &d3d, nullptr, nullptr);
    if (FAILED(hr)) return hr;
    if (FAILED(hr = d3d->QueryInterface(__uuidof(IDXGIDevice), (void **)&dxgiDevice))) return hr;
    if (FAILED(hr = CreateDXGIFactory2(0, __uuidof(IDXGIFactory2), (void **)&factory))) return hr;
    D2D1_FACTORY_OPTIONS opts = {};
    if (FAILED(hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1), &opts, (void **)&d2dFactory))) return hr;
    if (FAILED(hr = d2dFactory->CreateDevice(dxgiDevice, &d2dDevice))) return hr;
    if (FAILED(hr = DCompositionCreateDevice(dxgiDevice, __uuidof(IDCompositionDevice), (void **)&dcomp))) return hr;
    D2D1_STROKE_STYLE_PROPERTIES round = D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND,
                                                                     D2D1_CAP_STYLE_ROUND, D2D1_LINE_JOIN_ROUND);
    if (FAILED(hr = d2dFactory->CreateStrokeStyle(round, nullptr, 0, &roundStroke))) return hr;
    return 0;
}

static HRESULT bindTarget(NWSurface *s) {
    IDXGISurface *buffer = nullptr;
    HRESULT hr = s->chain->GetBuffer(0, __uuidof(IDXGISurface), (void **)&buffer);
    if (FAILED(hr)) return hr;
    D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED));
    hr = s->dc->CreateBitmapFromDxgiSurface(buffer, &props, &s->target);
    buffer->Release();
    if (SUCCEEDED(hr)) s->dc->SetTarget(s->target);
    return hr;
}

extern "C" NWSurface *nw_surface_create(void *hwnd, int32_t w, int32_t h) {
    NWSurface *s = new NWSurface();
    s->hwnd = (HWND)hwnd;
    DXGI_SWAP_CHAIN_DESC1 desc = {};
    desc.Width = w;
    desc.Height = h;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
    if (FAILED(factory->CreateSwapChainForComposition(d3d, &desc, nullptr, &s->chain)) ||
        FAILED(d2dDevice->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &s->dc)) ||
        FAILED(bindTarget(s)) ||
        FAILED(s->dc->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 0), &s->brush)) ||
        FAILED(dcomp->CreateTargetForHwnd(s->hwnd, TRUE, &s->compTarget)) ||
        FAILED(dcomp->CreateVisual(&s->visual)) ||
        FAILED(s->visual->SetContent(s->chain)) ||
        FAILED(s->compTarget->SetRoot(s->visual)) ||
        FAILED(dcomp->Commit())) {
        nw_surface_destroy(s);
        return nullptr;
    }
    s->dc->SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
    return s;
}

extern "C" int32_t nw_surface_resize(NWSurface *s, int32_t w, int32_t h) {
    s->dc->SetTarget(nullptr);
    release(s->target);
    HRESULT hr = s->chain->ResizeBuffers(0, w, h, DXGI_FORMAT_UNKNOWN, 0);
    if (FAILED(hr)) return hr;
    return bindTarget(s);
}

extern "C" void nw_surface_destroy(NWSurface *s) {
    if (!s) return;
    release(s->visual);
    release(s->compTarget);
    release(s->brush);
    if (s->dc) s->dc->SetTarget(nullptr);
    release(s->target);
    release(s->dc);
    release(s->chain);
    delete s;
}

extern "C" void nw_begin(NWSurface *s) {
    s->dc->BeginDraw();
    s->dc->Clear(D2D1::ColorF(0, 0, 0, 0));
}

extern "C" void nw_glow(NWSurface *s, float x, float y, float radius, const float *stops, const NWColor *colours, int32_t count) {
    D2D1_GRADIENT_STOP gs[8];
    if (count > 8) count = 8;
    for (int i = 0; i < count; i++) gs[i] = {stops[i], colour(colours[i])};
    ID2D1GradientStopCollection *collection = nullptr;
    ID2D1RadialGradientBrush *brush = nullptr;
    if (SUCCEEDED(s->dc->CreateGradientStopCollection(gs, count, &collection)) &&
        SUCCEEDED(s->dc->CreateRadialGradientBrush(
            D2D1::RadialGradientBrushProperties(D2D1::Point2F(x, y), D2D1::Point2F(0, 0), radius, radius), collection, &brush))) {
        s->dc->FillEllipse(D2D1::Ellipse(D2D1::Point2F(x, y), radius, radius), brush);
    }
    release(brush);
    release(collection);
}

extern "C" void nw_disc(NWSurface *s, float x, float y, float radius, NWColor c) {
    s->brush->SetColor(colour(c));
    s->dc->FillEllipse(D2D1::Ellipse(D2D1::Point2F(x, y), radius, radius), s->brush);
}

static ID2D1PathGeometry *path(const float *xy, int32_t count, bool closed) {
    ID2D1PathGeometry *g = nullptr;
    ID2D1GeometrySink *sink = nullptr;
    if (FAILED(d2dFactory->CreatePathGeometry(&g))) return nullptr;
    if (FAILED(g->Open(&sink))) { release(g); return nullptr; }
    sink->BeginFigure(D2D1::Point2F(xy[0], xy[1]), closed ? D2D1_FIGURE_BEGIN_FILLED : D2D1_FIGURE_BEGIN_HOLLOW);
    for (int i = 1; i < count; i++) sink->AddLine(D2D1::Point2F(xy[2 * i], xy[2 * i + 1]));
    sink->EndFigure(closed ? D2D1_FIGURE_END_CLOSED : D2D1_FIGURE_END_OPEN);
    sink->Close();
    sink->Release();
    return g;
}

extern "C" void nw_polyline(NWSurface *s, const float *xy, int32_t count, float width, NWColor c) {
    if (count < 2) return;
    ID2D1PathGeometry *g = path(xy, count, false);
    if (!g) return;
    s->brush->SetColor(colour(c));
    s->dc->DrawGeometry(g, s->brush, width, roundStroke);
    g->Release();
}

extern "C" void nw_fill_polygon(NWSurface *s, const float *xy, int32_t count, NWColor c) {
    if (count < 3) return;
    ID2D1PathGeometry *g = path(xy, count, true);
    if (!g) return;
    s->brush->SetColor(colour(c));
    s->dc->FillGeometry(g, s->brush);
    g->Release();
}

extern "C" int32_t nw_end(NWSurface *s) {
    HRESULT hr = s->dc->EndDraw();
    if (FAILED(hr)) return hr;
    return s->chain->Present(0, 0);
}

typedef DWORD(WINAPI *WaitClock)(UINT, const HANDLE *, DWORD);

extern "C" int32_t nw_wait_frame(void) {
    static WaitClock wait = (WaitClock)GetProcAddress(LoadLibraryW(L"dcomp.dll"), "DCompositionWaitForCompositorClock");
    if (wait) { wait(0, nullptr, 100); return 1; }
    DwmFlush();
    return 0;
}

extern "C" double nw_refresh_period(void) {
    DWM_TIMING_INFO info = {};
    info.cbSize = sizeof(info);
    LARGE_INTEGER f;
    if (FAILED(DwmGetCompositionTimingInfo(nullptr, &info)) || !QueryPerformanceFrequency(&f)) return 0;
    return (double)info.qpcRefreshPeriod / (double)f.QuadPart;
}

extern "C" double nw_now(void) {
    static LARGE_INTEGER f = [] { LARGE_INTEGER x; QueryPerformanceFrequency(&x); return x; }();
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return (double)t.QuadPart / (double)f.QuadPart;
}

// Direct3D 11 viewport renderer: executes the draw plan of ForgeRender.ViewportPlan with
// pipelines equivalent to the Metal ones (MetalViewportRenderer.swift), GPU picking into two
// R32_UINT targets, and a Direct2D layer for labels. Shaders are HLSL compiled at start-up
// (d3dcompiler_47.dll, part of Windows).

#include "fw_internal.h"

#include <d2d1_1.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dwrite.h>
#include <dxgi1_2.h>

#include <cstring>
#include <algorithm>
#include <map>

template <class T> static void release(T *&p) {
    if (p) {
        p->Release();
        p = nullptr;
    }
}

struct fw_buffer {
    ID3D11Buffer *buffer = nullptr;
};

struct fw_renderer {
    HWND hwnd = nullptr;
    ID3D11Device *device = nullptr;
    ID3D11DeviceContext *context = nullptr;
    IDXGISwapChain1 *swapchain = nullptr;
    ID3D11RenderTargetView *rtv = nullptr;
    ID3D11Texture2D *depth = nullptr;
    ID3D11DepthStencilView *dsv = nullptr;
    int width = 0, height = 0;

    ID3D11VertexShader *triVS = nullptr, *lineVS = nullptr, *gradientVS = nullptr;
    ID3D11PixelShader *shadedPS = nullptr, *linePS = nullptr, *previewPS = nullptr, *pickPS = nullptr, *gradientPS = nullptr;
    ID3D11InputLayout *triLayout = nullptr, *lineLayout = nullptr;
    ID3D11Buffer *uniforms = nullptr;
    ID3D11BlendState *alphaBlend = nullptr;
    ID3D11DepthStencilState *depthWrite = nullptr, *depthTest = nullptr, *depthNone = nullptr;
    ID3D11RasterizerState *raster = nullptr;

    // Pick targets (created at the viewport size when a pick runs).
    ID3D11Texture2D *pickObj = nullptr, *pickEl = nullptr, *pickDepth = nullptr;
    ID3D11RenderTargetView *pickObjRTV = nullptr, *pickElRTV = nullptr;
    ID3D11DepthStencilView *pickDSV = nullptr;
    int pickW = 0, pickH = 0;

    // Direct2D on the back buffer.
    ID2D1Factory1 *d2dFactory = nullptr;
    ID2D1Device *d2dDevice = nullptr;
    ID2D1DeviceContext *d2d = nullptr;
    ID2D1Bitmap1 *target = nullptr;
    IDWriteFactory *dwrite = nullptr;
    std::map<std::pair<int, int>, IDWriteTextFormat *> formats;
    bool drawing2D = false;
    bool inFrame = false;
};

static const char *kShaders = R"HLSL(
cbuffer Uniforms : register(b0) {
    float4x4 viewProj;
    float4 color;
    float4 highlight;
    float4 lightDir;
    float4 viewDir;
    uint4 ids;   // x = objectID + 1, y = hidden-line mode
};

struct TriIn { float3 position : POSITION; float3 normal : NORMAL; uint element : ELEMENT; uint highlighted : HIGHLIGHT; };
struct LineIn { float3 position : POSITION; uint element : ELEMENT; uint highlighted : HIGHLIGHT; float3 color : COLOR; };

struct VOut {
    float4 position : SV_Position;
    float3 normal : NORMAL;
    float3 color : COLOR;
    nointerpolation uint element : ELEMENT;
    nointerpolation uint highlighted : HIGHLIGHT;
};

VOut tri_vs(TriIn v) {
    VOut o;
    o.position = mul(viewProj, float4(v.position, 1.0));
    o.normal = v.normal;
    o.color = float3(0, 0, 0);
    o.element = v.element;
    o.highlighted = v.highlighted;
    return o;
}

VOut line_vs(LineIn v) {
    VOut o;
    o.position = mul(viewProj, float4(v.position, 1.0));
    o.position.z -= 0.0015 * o.position.w;   // edges on top of their faces
    o.normal = float3(0, 0, 0);
    o.color = v.color;
    o.element = v.element;
    o.highlighted = v.highlighted;
    return o;
}

float4 shaded_ps(VOut i) : SV_Target {
    if (ids.y != 0) { return float4(1, 1, 1, 1); }
    float3 base = i.highlighted != 0 ? highlight.rgb : color.rgb;
    float3 n = normalize(i.normal);
    if (dot(n, viewDir.xyz) < 0.0) { n = -n; }
    float diffuse = max(0.0, dot(n, lightDir.xyz));
    float3 h = normalize(lightDir.xyz + viewDir.xyz);
    float spec = pow(max(0.0, dot(n, h)), 40.0) * 0.25;
    return float4(min(float3(1, 1, 1), base * (0.3 + 0.7 * diffuse) + spec), 1.0);
}

float4 preview_ps(VOut i) : SV_Target {
    float3 n = normalize(i.normal);
    if (dot(n, viewDir.xyz) < 0.0) { n = -n; }
    float diffuse = max(0.0, dot(n, lightDir.xyz));
    return float4(color.rgb * (0.55 + 0.45 * diffuse), color.a);
}

float4 line_ps(VOut i) : SV_Target {
    return i.highlighted != 0 ? float4(highlight.rgb, 1.0) : float4(i.color, 1.0);
}

struct PickOut { uint object : SV_Target0; uint element : SV_Target1; };

PickOut pick_ps(VOut i) {
    PickOut o;
    o.object = ids.x;
    o.element = i.element;
    return o;
}

// Background: a full-screen triangle with a vertical gradient (colour = top, highlight = bottom).
struct GOut { float4 position : SV_Position; float t : TEXCOORD0; };

GOut gradient_vs(uint id : SV_VertexID) {
    GOut o;
    float2 p = float2((id << 1) & 2, id & 2);
    o.position = float4(p * float2(2, -2) + float2(-1, 1), 1.0, 1.0);
    o.t = p.y;
    return o;
}

float4 gradient_ps(GOut i) : SV_Target {
    return lerp(color, highlight, saturate(i.t));
}
)HLSL";

typedef HRESULT(WINAPI *D3DCompileFn)(LPCVOID, SIZE_T, LPCSTR, const D3D_SHADER_MACRO *, ID3DInclude *, LPCSTR, LPCSTR, UINT, UINT, ID3DBlob **,
                                      ID3DBlob **);

static ID3DBlob *compile(D3DCompileFn fn, const char *entry, const char *profile) {
    ID3DBlob *code = nullptr, *errors = nullptr;
    HRESULT hr = fn(kShaders, strlen(kShaders), "forge.hlsl", nullptr, nullptr, entry, profile, D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &errors);
    if (FAILED(hr)) {
        if (errors) OutputDebugStringA((const char *)errors->GetBufferPointer());
        release(errors);
        release(code);
        return nullptr;
    }
    release(errors);
    return code;
}

static bool createTargets(fw_renderer *r) {
    ID3D11Texture2D *back = nullptr;
    if (FAILED(r->swapchain->GetBuffer(0, __uuidof(ID3D11Texture2D), (void **)&back))) return false;
    D3D11_RENDER_TARGET_VIEW_DESC rd = {};
    rd.Format = DXGI_FORMAT_B8G8R8A8_UNORM_SRGB;  // lit colours are linear, like the Metal bgra8Unorm_srgb target
    rd.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
    HRESULT hr = r->device->CreateRenderTargetView(back, &rd, &r->rtv);
    back->Release();
    if (FAILED(hr)) return false;
    D3D11_TEXTURE2D_DESC dd = {};
    dd.Width = (UINT)r->width;
    dd.Height = (UINT)r->height;
    dd.MipLevels = 1;
    dd.ArraySize = 1;
    dd.Format = DXGI_FORMAT_D32_FLOAT;
    dd.SampleDesc.Count = 1;
    dd.BindFlags = D3D11_BIND_DEPTH_STENCIL;
    if (FAILED(r->device->CreateTexture2D(&dd, nullptr, &r->depth))) return false;
    if (FAILED(r->device->CreateDepthStencilView(r->depth, nullptr, &r->dsv))) return false;
    if (r->d2d) {
        IDXGISurface *surface = nullptr;
        if (SUCCEEDED(r->swapchain->GetBuffer(0, __uuidof(IDXGISurface), (void **)&surface))) {
            D2D1_BITMAP_PROPERTIES1 bp = {};
            bp.pixelFormat = {DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED};
            bp.bitmapOptions = D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW;
            r->d2d->CreateBitmapFromDxgiSurface(surface, &bp, &r->target);
            surface->Release();
        }
    }
    return true;
}

static void releaseTargets(fw_renderer *r) {
    if (r->d2d) r->d2d->SetTarget(nullptr);
    release(r->target);
    release(r->rtv);
    release(r->dsv);
    release(r->depth);
}

static void releasePick(fw_renderer *r) {
    release(r->pickObjRTV);
    release(r->pickElRTV);
    release(r->pickDSV);
    release(r->pickObj);
    release(r->pickEl);
    release(r->pickDepth);
    r->pickW = r->pickH = 0;
}

fw_renderer *fw_renderer_create(HWND view) {
    auto *r = new fw_renderer();
    r->hwnd = view;
    RECT rc;
    GetClientRect(view, &rc);
    r->width = std::max(1L, rc.right);
    r->height = std::max(1L, rc.bottom);

    D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;  // Direct2D interop
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, levels, 4, D3D11_SDK_VERSION, &r->device, nullptr, &r->context);
    if (FAILED(hr)) hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, levels, 4, D3D11_SDK_VERSION, &r->device, nullptr, &r->context);
    if (FAILED(hr)) {
        delete r;
        return nullptr;
    }

    IDXGIDevice *dxgiDevice = nullptr;
    IDXGIAdapter *adapter = nullptr;
    IDXGIFactory2 *factory = nullptr;
    r->device->QueryInterface(__uuidof(IDXGIDevice), (void **)&dxgiDevice);
    if (dxgiDevice) dxgiDevice->GetAdapter(&adapter);
    if (adapter) adapter->GetParent(__uuidof(IDXGIFactory2), (void **)&factory);
    if (!factory) {
        release(adapter);
        release(dxgiDevice);
        fw_renderer_destroy(r);
        return nullptr;
    }
    DXGI_SWAP_CHAIN_DESC1 sd = {};
    sd.Width = (UINT)r->width;
    sd.Height = (UINT)r->height;
    sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    hr = factory->CreateSwapChainForHwnd(r->device, view, &sd, nullptr, nullptr, &r->swapchain);
    if (FAILED(hr)) {
        // Older systems: flip-sequential, then blit model.
        sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
        hr = factory->CreateSwapChainForHwnd(r->device, view, &sd, nullptr, nullptr, &r->swapchain);
    }
    factory->MakeWindowAssociation(view, DXGI_MWA_NO_ALT_ENTER);
    factory->Release();
    adapter->Release();
    if (FAILED(hr)) {
        release(dxgiDevice);
        fw_renderer_destroy(r);
        return nullptr;
    }

    // Direct2D + DirectWrite for labels.
    D2D1_FACTORY_OPTIONS fo = {};
    if (SUCCEEDED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1), &fo, (void **)&r->d2dFactory))) {
        if (SUCCEEDED(r->d2dFactory->CreateDevice(dxgiDevice, &r->d2dDevice)))
            r->d2dDevice->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &r->d2d);
    }
    DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), (IUnknown **)&r->dwrite);
    release(dxgiDevice);

    // Shaders.
    HMODULE compiler = LoadLibraryW(L"d3dcompiler_47.dll");
    auto compileFn = compiler ? (D3DCompileFn)(void *)GetProcAddress(compiler, "D3DCompile") : nullptr;
    if (!compileFn) {
        fw_renderer_destroy(r);
        return nullptr;
    }
    ID3DBlob *tri = compile(compileFn, "tri_vs", "vs_4_0"), *line = compile(compileFn, "line_vs", "vs_4_0"), *grad = compile(compileFn, "gradient_vs", "vs_4_0");
    ID3DBlob *shaded = compile(compileFn, "shaded_ps", "ps_4_0"), *lineP = compile(compileFn, "line_ps", "ps_4_0");
    ID3DBlob *prev = compile(compileFn, "preview_ps", "ps_4_0"), *pick = compile(compileFn, "pick_ps", "ps_4_0"), *gradP = compile(compileFn, "gradient_ps", "ps_4_0");
    bool ok = tri && line && grad && shaded && lineP && prev && pick && gradP;
    if (ok) {
        r->device->CreateVertexShader(tri->GetBufferPointer(), tri->GetBufferSize(), nullptr, &r->triVS);
        r->device->CreateVertexShader(line->GetBufferPointer(), line->GetBufferSize(), nullptr, &r->lineVS);
        r->device->CreateVertexShader(grad->GetBufferPointer(), grad->GetBufferSize(), nullptr, &r->gradientVS);
        r->device->CreatePixelShader(shaded->GetBufferPointer(), shaded->GetBufferSize(), nullptr, &r->shadedPS);
        r->device->CreatePixelShader(lineP->GetBufferPointer(), lineP->GetBufferSize(), nullptr, &r->linePS);
        r->device->CreatePixelShader(prev->GetBufferPointer(), prev->GetBufferSize(), nullptr, &r->previewPS);
        r->device->CreatePixelShader(pick->GetBufferPointer(), pick->GetBufferSize(), nullptr, &r->pickPS);
        r->device->CreatePixelShader(gradP->GetBufferPointer(), gradP->GetBufferSize(), nullptr, &r->gradientPS);
        // Must match ForgeRender.ViewportVertices (32-byte vertices).
        D3D11_INPUT_ELEMENT_DESC triDesc[] = {
            {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
            {"NORMAL", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0},
            {"ELEMENT", 0, DXGI_FORMAT_R32_UINT, 0, 24, D3D11_INPUT_PER_VERTEX_DATA, 0},
            {"HIGHLIGHT", 0, DXGI_FORMAT_R32_UINT, 0, 28, D3D11_INPUT_PER_VERTEX_DATA, 0},
        };
        D3D11_INPUT_ELEMENT_DESC lineDesc[] = {
            {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
            {"ELEMENT", 0, DXGI_FORMAT_R32_UINT, 0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0},
            {"HIGHLIGHT", 0, DXGI_FORMAT_R32_UINT, 0, 16, D3D11_INPUT_PER_VERTEX_DATA, 0},
            {"COLOR", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 20, D3D11_INPUT_PER_VERTEX_DATA, 0},
        };
        r->device->CreateInputLayout(triDesc, 4, tri->GetBufferPointer(), tri->GetBufferSize(), &r->triLayout);
        r->device->CreateInputLayout(lineDesc, 4, line->GetBufferPointer(), line->GetBufferSize(), &r->lineLayout);
    }
    for (ID3DBlob *b : {tri, line, grad, shaded, lineP, prev, pick, gradP})
        if (b) b->Release();
    if (!ok || !r->triLayout || !r->lineLayout) {
        fw_renderer_destroy(r);
        return nullptr;
    }

    D3D11_BUFFER_DESC cb = {};
    cb.ByteWidth = 36 * 4;
    cb.Usage = D3D11_USAGE_DYNAMIC;
    cb.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    cb.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    r->device->CreateBuffer(&cb, nullptr, &r->uniforms);

    D3D11_BLEND_DESC bd = {};
    bd.RenderTarget[0].BlendEnable = TRUE;
    bd.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
    bd.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    bd.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    bd.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    bd.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    bd.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    bd.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    r->device->CreateBlendState(&bd, &r->alphaBlend);

    D3D11_DEPTH_STENCIL_DESC ds = {};
    ds.DepthEnable = TRUE;
    ds.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ALL;
    ds.DepthFunc = D3D11_COMPARISON_LESS_EQUAL;
    r->device->CreateDepthStencilState(&ds, &r->depthWrite);
    ds.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ZERO;
    r->device->CreateDepthStencilState(&ds, &r->depthTest);
    ds.DepthEnable = FALSE;
    ds.DepthFunc = D3D11_COMPARISON_ALWAYS;
    r->device->CreateDepthStencilState(&ds, &r->depthNone);

    D3D11_RASTERIZER_DESC rs = {};
    rs.FillMode = D3D11_FILL_SOLID;
    rs.CullMode = D3D11_CULL_NONE;
    rs.DepthClipEnable = TRUE;
    r->device->CreateRasterizerState(&rs, &r->raster);

    if (!createTargets(r)) {
        fw_renderer_destroy(r);
        return nullptr;
    }
    return r;
}

void fw_renderer_destroy(fw_renderer *r) {
    if (!r) return;
    releaseTargets(r);
    releasePick(r);
    for (auto &f : r->formats) f.second->Release();
    release(r->dwrite);
    release(r->d2d);
    release(r->d2dDevice);
    release(r->d2dFactory);
    release(r->raster);
    release(r->depthWrite);
    release(r->depthTest);
    release(r->depthNone);
    release(r->alphaBlend);
    release(r->uniforms);
    release(r->triLayout);
    release(r->lineLayout);
    release(r->triVS);
    release(r->lineVS);
    release(r->gradientVS);
    release(r->shadedPS);
    release(r->linePS);
    release(r->previewPS);
    release(r->pickPS);
    release(r->gradientPS);
    release(r->swapchain);
    release(r->context);
    release(r->device);
    delete r;
}

void fw_renderer_resize(fw_renderer *r, int width, int height) {
    if (!r || width <= 0 || height <= 0 || (width == r->width && height == r->height)) return;
    r->width = width;
    r->height = height;
    r->context->OMSetRenderTargets(0, nullptr, nullptr);
    releaseTargets(r);
    releasePick(r);
    r->context->Flush();
    r->swapchain->ResizeBuffers(0, (UINT)width, (UINT)height, DXGI_FORMAT_UNKNOWN, 0);
    createTargets(r);
}

// MARK: C API

extern "C" fw_buffer *fw_buffer_create(fw_app *a, const void *bytes, int length) {
    fw_renderer *r = a->renderer;
    if (!r || !bytes || length <= 0) return nullptr;
    D3D11_BUFFER_DESC d = {};
    d.ByteWidth = (UINT)length;
    d.Usage = D3D11_USAGE_IMMUTABLE;
    d.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    D3D11_SUBRESOURCE_DATA init = {bytes, 0, 0};
    auto *b = new fw_buffer();
    if (FAILED(r->device->CreateBuffer(&d, &init, &b->buffer))) {
        delete b;
        return nullptr;
    }
    return b;
}

extern "C" void fw_buffer_release(fw_buffer *b) {
    if (!b) return;
    release(b->buffer);
    delete b;
}

static void setUniforms(fw_renderer *r, const float *u) {
    D3D11_MAPPED_SUBRESOURCE m;
    if (SUCCEEDED(r->context->Map(r->uniforms, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) {
        memcpy(m.pData, u, 36 * 4);
        r->context->Unmap(r->uniforms, 0);
    }
}

static void viewport(fw_renderer *r) {
    D3D11_VIEWPORT vp = {0, 0, (float)r->width, (float)r->height, 0, 1};
    r->context->RSSetViewports(1, &vp);
    r->context->RSSetState(r->raster);
    r->context->VSSetConstantBuffers(0, 1, &r->uniforms);
    r->context->PSSetConstantBuffers(0, 1, &r->uniforms);
}

extern "C" int fw_frame_begin(fw_app *a, const float top[4], const float bottom[4]) {
    fw_renderer *r = a->renderer;
    if (!r || !r->rtv) return 0;
    r->inFrame = true;
    r->drawing2D = false;
    r->context->OMSetRenderTargets(1, &r->rtv, r->dsv);
    r->context->ClearDepthStencilView(r->dsv, D3D11_CLEAR_DEPTH, 1.0f, 0);
    viewport(r);
    float u[36] = {};
    memcpy(u + 16, top, 16);
    memcpy(u + 20, bottom, 16);
    setUniforms(r, u);
    r->context->OMSetDepthStencilState(r->depthNone, 0);
    r->context->OMSetBlendState(nullptr, nullptr, 0xffffffff);
    r->context->IASetInputLayout(nullptr);
    r->context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    r->context->VSSetShader(r->gradientVS, nullptr, 0);
    r->context->PSSetShader(r->gradientPS, nullptr, 0);
    r->context->Draw(3, 0);
    return 1;
}

extern "C" void fw_draw(fw_app *a, int pipeline, int depth, fw_buffer *b, int vertex_count, const float *u) {
    fw_renderer *r = a->renderer;
    if (!r || !b || !b->buffer || vertex_count <= 0) return;
    bool lines = pipeline == 1 || pipeline == 4;
    setUniforms(r, u);
    r->context->IASetInputLayout(lines ? r->lineLayout : r->triLayout);
    r->context->IASetPrimitiveTopology(lines ? D3D11_PRIMITIVE_TOPOLOGY_LINELIST : D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    UINT stride = 32, offset = 0;
    r->context->IASetVertexBuffers(0, 1, &b->buffer, &stride, &offset);
    r->context->VSSetShader(lines ? r->lineVS : r->triVS, nullptr, 0);
    ID3D11PixelShader *ps = pipeline == 0 ? r->shadedPS : pipeline == 1 ? r->linePS : pipeline == 2 ? r->previewPS : r->pickPS;
    r->context->PSSetShader(ps, nullptr, 0);
    r->context->OMSetBlendState(pipeline == 2 ? r->alphaBlend : nullptr, nullptr, 0xffffffff);
    r->context->OMSetDepthStencilState(depth == 0 ? r->depthWrite : depth == 1 ? r->depthTest : r->depthNone, 0);
    r->context->Draw((UINT)vertex_count, 0);
}

static D2D1_COLOR_F color(uint32_t rgba) {
    return D2D1::ColorF(((rgba >> 24) & 255) / 255.0f, ((rgba >> 16) & 255) / 255.0f, ((rgba >> 8) & 255) / 255.0f, (rgba & 255) / 255.0f);
}

static bool begin2D(fw_renderer *r) {
    if (!r->d2d || !r->target || !r->inFrame) return false;
    if (!r->drawing2D) {
        r->context->Flush();
        r->d2d->SetTarget(r->target);
        r->d2d->BeginDraw();
        r->drawing2D = true;
    }
    return true;
}

static IDWriteTextFormat *format(fw_renderer *r, float size, bool centred) {
    auto key = std::make_pair((int)(size * 4), centred ? 1 : 0);
    auto it = r->formats.find(key);
    if (it != r->formats.end()) return it->second;
    IDWriteTextFormat *f = nullptr;
    if (!r->dwrite || FAILED(r->dwrite->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_FONT_STYLE_NORMAL,
                                                         DWRITE_FONT_STRETCH_NORMAL, size, L"", &f)))
        return nullptr;
    f->SetTextAlignment(centred ? DWRITE_TEXT_ALIGNMENT_CENTER : DWRITE_TEXT_ALIGNMENT_LEADING);
    f->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    f->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    r->formats[key] = f;
    return f;
}

extern "C" void fw_text(fw_app *a, const char *text, float x, float y, float size, uint32_t rgba, int align, int boxed) {
    fw_renderer *r = a->renderer;
    if (!r || !begin2D(r)) return;
    std::wstring w = fw_widen(text);
    IDWriteTextFormat *f = format(r, size, align == 1);
    if (!f || w.empty()) return;
    IDWriteTextLayout *layout = nullptr;
    if (FAILED(r->dwrite->CreateTextLayout(w.c_str(), (UINT32)w.size(), f, 4000, size * 2, &layout))) return;
    DWRITE_TEXT_METRICS m = {};
    layout->GetMetrics(&m);
    layout->Release();
    float tw = m.widthIncludingTrailingWhitespace, th = size * 1.4f;
    float left = align == 1 ? x - tw / 2 : x;
    D2D1_RECT_F rect = D2D1::RectF(left, y - th / 2, left + tw, y + th / 2);
    ID2D1SolidColorBrush *brush = nullptr;
    if (boxed) {
        D2D1_ROUNDED_RECT box = {D2D1::RectF(rect.left - size * 0.45f, rect.top, rect.right + size * 0.45f, rect.bottom), size * 0.35f, size * 0.35f};
        if (SUCCEEDED(r->d2d->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 0.92f), &brush))) {
            r->d2d->FillRoundedRectangle(box, brush);
            brush->SetColor(D2D1::ColorF(0.78f, 0.80f, 0.84f, 1));
            r->d2d->DrawRoundedRectangle(box, brush, 1);
            brush->Release();
            brush = nullptr;
        }
    }
    if (SUCCEEDED(r->d2d->CreateSolidColorBrush(color(rgba), &brush))) {
        r->d2d->DrawText(w.c_str(), (UINT32)w.size(), f, rect, brush, D2D1_DRAW_TEXT_OPTIONS_NONE);
        brush->Release();
    }
}

extern "C" void fw_line2d(fw_app *a, float x0, float y0, float x1, float y1, float width, uint32_t rgba) {
    fw_renderer *r = a->renderer;
    if (!r || !begin2D(r)) return;
    ID2D1SolidColorBrush *brush = nullptr;
    if (SUCCEEDED(r->d2d->CreateSolidColorBrush(color(rgba), &brush))) {
        r->d2d->DrawLine(D2D1::Point2F(x0, y0), D2D1::Point2F(x1, y1), brush, width);
        brush->Release();
    }
}

extern "C" void fw_frame_end(fw_app *a) {
    fw_renderer *r = a->renderer;
    if (!r || !r->inFrame) return;
    if (r->drawing2D) {
        r->d2d->EndDraw();
        r->d2d->SetTarget(nullptr);
        r->drawing2D = false;
    }
    r->inFrame = false;
    r->swapchain->Present(1, 0);
}

// MARK: picking

extern "C" int fw_pick_begin(fw_app *a) {
    fw_renderer *r = a->renderer;
    if (!r) return 0;
    if (r->pickW != r->width || r->pickH != r->height) {
        releasePick(r);
        D3D11_TEXTURE2D_DESC d = {};
        d.Width = (UINT)r->width;
        d.Height = (UINT)r->height;
        d.MipLevels = 1;
        d.ArraySize = 1;
        d.Format = DXGI_FORMAT_R32_UINT;
        d.SampleDesc.Count = 1;
        d.BindFlags = D3D11_BIND_RENDER_TARGET;
        if (FAILED(r->device->CreateTexture2D(&d, nullptr, &r->pickObj)) || FAILED(r->device->CreateTexture2D(&d, nullptr, &r->pickEl))) return 0;
        d.Format = DXGI_FORMAT_D32_FLOAT;
        d.BindFlags = D3D11_BIND_DEPTH_STENCIL;
        if (FAILED(r->device->CreateTexture2D(&d, nullptr, &r->pickDepth))) return 0;
        if (FAILED(r->device->CreateRenderTargetView(r->pickObj, nullptr, &r->pickObjRTV)) ||
            FAILED(r->device->CreateRenderTargetView(r->pickEl, nullptr, &r->pickElRTV)) ||
            FAILED(r->device->CreateDepthStencilView(r->pickDepth, nullptr, &r->pickDSV)))
            return 0;
        r->pickW = r->width;
        r->pickH = r->height;
    }
    ID3D11RenderTargetView *targets[2] = {r->pickObjRTV, r->pickElRTV};
    r->context->OMSetRenderTargets(2, targets, r->pickDSV);
    UINT zero[4] = {0, 0, 0, 0};
    r->context->ClearRenderTargetView(r->pickObjRTV, (const float *)zero);
    r->context->ClearRenderTargetView(r->pickElRTV, (const float *)zero);
    r->context->ClearDepthStencilView(r->pickDSV, D3D11_CLEAR_DEPTH, 1.0f, 0);
    viewport(r);
    return 1;
}

extern "C" int fw_pick_end(fw_app *a, int x0, int y0, int w, int h, uint32_t *objects, uint32_t *elements) {
    fw_renderer *r = a->renderer;
    if (!r || !r->pickObj || w <= 0 || h <= 0) return 0;
    D3D11_TEXTURE2D_DESC d = {};
    d.Width = (UINT)w;
    d.Height = (UINT)h;
    d.MipLevels = 1;
    d.ArraySize = 1;
    d.Format = DXGI_FORMAT_R32_UINT;
    d.SampleDesc.Count = 1;
    d.Usage = D3D11_USAGE_STAGING;
    d.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    int ok = 1;
    for (int t = 0; t < 2; ++t) {
        ID3D11Texture2D *staging = nullptr;
        if (FAILED(r->device->CreateTexture2D(&d, nullptr, &staging))) return 0;
        D3D11_BOX box = {(UINT)x0, (UINT)y0, 0, (UINT)(x0 + w), (UINT)(y0 + h), 1};
        r->context->CopySubresourceRegion(staging, 0, 0, 0, 0, t == 0 ? r->pickObj : r->pickEl, 0, &box);
        D3D11_MAPPED_SUBRESOURCE m;
        if (SUCCEEDED(r->context->Map(staging, 0, D3D11_MAP_READ, 0, &m))) {
            uint32_t *out = t == 0 ? objects : elements;
            for (int row = 0; row < h; ++row) memcpy(out + row * w, (const uint8_t *)m.pData + row * m.RowPitch, (size_t)w * 4);
            r->context->Unmap(staging, 0);
        } else {
            ok = 0;
        }
        staging->Release();
    }
    r->context->OMSetRenderTargets(1, &r->rtv, r->dsv);
    return ok;
}

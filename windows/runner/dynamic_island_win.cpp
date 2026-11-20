#include "dynamic_island_win.h"

#include <d2d1.h>
#include <dwrite.h>
#include <objbase.h>
#include <wincodec.h>

#include <algorithm>
#include <cmath>

namespace {

constexpr wchar_t kIslandClassName[] = L"MaterialDropDynamicIslandWnd";
constexpr UINT_PTR kAnimTimerId = 41;
constexpr int kMaxPillWidth = 460;
constexpr int kMinPillWidth = 280;
constexpr int kPillHeight = 68;
constexpr int kHaloPad = 14;

struct ButtonHitRect {
  std::string action;
  D2D1_RECT_F rect{};
  bool primary = false;
  std::wstring label;
};

D2D1_COLOR_F ArgbToColorF(uint32_t argb, float alpha_override = -1.0f) {
  float a = alpha_override >= 0.0f
                ? alpha_override
                : static_cast<float>((argb >> 24) & 0xFF) / 255.0f;
  float r = static_cast<float>((argb >> 16) & 0xFF) / 255.0f;
  float g = static_cast<float>((argb >> 8) & 0xFF) / 255.0f;
  float b = static_cast<float>(argb & 0xFF) / 255.0f;
  return D2D1::ColorF(r, g, b, a);
}

IWICBitmapSource* DecodeThumbnailFromPng(IWICImagingFactory* wic,
                                         const std::vector<uint8_t>& bytes) {
  if (!wic || bytes.empty()) return nullptr;
  HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
  if (!hMem) return nullptr;
  void* dst = GlobalLock(hMem);
  if (!dst) {
    GlobalFree(hMem);
    return nullptr;
  }
  memcpy(dst, bytes.data(), bytes.size());
  GlobalUnlock(hMem);

  IStream* stream = nullptr;
  if (FAILED(CreateStreamOnHGlobal(hMem, TRUE, &stream)) || !stream) {
    GlobalFree(hMem);
    return nullptr;
  }

  IWICBitmapDecoder* decoder = nullptr;
  IWICBitmapFrameDecode* frame = nullptr;
  IWICFormatConverter* converter = nullptr;
  IWICBitmapSource* out = nullptr;

  if (SUCCEEDED(wic->CreateDecoderFromStream(
          stream, nullptr, WICDecodeMetadataCacheOnDemand, &decoder)) &&
      decoder && SUCCEEDED(decoder->GetFrame(0, &frame)) && frame &&
      SUCCEEDED(wic->CreateFormatConverter(&converter)) && converter &&
      SUCCEEDED(converter->Initialize(frame, GUID_WICPixelFormat32bppPBGRA,
                                      WICBitmapDitherTypeNone, nullptr, 0.0,
                                      WICBitmapPaletteTypeCustom))) {
    out = converter;
    out->AddRef();
  }

  if (converter) converter->Release();
  if (frame) frame->Release();
  if (decoder) decoder->Release();
  stream->Release();
  return out;
}

}  // namespace

struct DynamicIslandWin::Impl {
  ActionCallback on_action;
  HWND hwnd = nullptr;
  bool class_registered = false;
  bool visible = false;
  float anim_progress = 0.0f;
  float anim_target = 0.0f;

  DynamicIslandPayloadWin payload;
  std::vector<ButtonHitRect> button_rects;

  ID2D1Factory* d2d = nullptr;
  ID2D1DCRenderTarget* rt = nullptr;
  IDWriteFactory* dwrite = nullptr;
  IDWriteTextFormat* title_fmt = nullptr;
  IDWriteTextFormat* sub_fmt = nullptr;
  IDWriteTextFormat* btn_fmt = nullptr;
  IWICImagingFactory* wic = nullptr;
  IWICBitmapSource* thumb_wic = nullptr;

  ~Impl() {
    ReleaseThumb();
    if (title_fmt) title_fmt->Release();
    if (sub_fmt) sub_fmt->Release();
    if (btn_fmt) btn_fmt->Release();
    if (dwrite) dwrite->Release();
    if (rt) rt->Release();
    if (d2d) d2d->Release();
    if (wic) wic->Release();
  }

  void ReleaseThumb() {
    if (thumb_wic) {
      thumb_wic->Release();
      thumb_wic = nullptr;
    }
  }

  bool EnsureResources() {
    if (!d2d) {
      if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &d2d))) {
        return false;
      }
    }
    if (!rt) {
      D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
          D2D1_RENDER_TARGET_TYPE_DEFAULT,
          D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                            D2D1_ALPHA_MODE_PREMULTIPLIED));
      if (FAILED(d2d->CreateDCRenderTarget(&props, &rt))) {
        return false;
      }
    }
    if (!dwrite) {
      if (FAILED(DWriteCreateFactory(
              DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
              reinterpret_cast<IUnknown**>(&dwrite)))) {
        return false;
      }
    }
    if (!title_fmt) {
      dwrite->CreateTextFormat(L"Segoe UI Variable Text", nullptr,
                               DWRITE_FONT_WEIGHT_SEMI_BOLD,
                               DWRITE_FONT_STYLE_NORMAL,
                               DWRITE_FONT_STRETCH_NORMAL, 13.5f, L"",
                               &title_fmt);
      if (title_fmt) {
        title_fmt->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        DWRITE_TRIMMING trim{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
        title_fmt->SetTrimming(&trim, nullptr);
      }
    }
    if (!sub_fmt) {
      dwrite->CreateTextFormat(L"Segoe UI Variable Text", nullptr,
                               DWRITE_FONT_WEIGHT_NORMAL,
                               DWRITE_FONT_STYLE_NORMAL,
                               DWRITE_FONT_STRETCH_NORMAL, 11.5f, L"",
                               &sub_fmt);
      if (sub_fmt) {
        sub_fmt->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        DWRITE_TRIMMING trim{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
        sub_fmt->SetTrimming(&trim, nullptr);
      }
    }
    if (!btn_fmt) {
      dwrite->CreateTextFormat(L"Segoe UI Variable Text", nullptr,
                               DWRITE_FONT_WEIGHT_SEMI_BOLD,
                               DWRITE_FONT_STYLE_NORMAL,
                               DWRITE_FONT_STRETCH_NORMAL, 11.5f, L"",
                               &btn_fmt);
      if (btn_fmt) {
        btn_fmt->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
        btn_fmt->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
      }
    }
    if (!wic) {
      CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                       IID_PPV_ARGS(&wic));
    }
    return true;
  }

  void RenderLayeredFrame() {
    if (!hwnd || !EnsureResources()) return;

    int pill_w = payload.buttons.empty() ? 336 : kMaxPillWidth;
    pill_w = std::clamp(pill_w, kMinPillWidth, kMaxPillWidth);
    const int win_w = pill_w + kHaloPad * 2;
    const int win_h = kPillHeight + kHaloPad * 2;

    RECT work{};
    POINT pt_zero{0, 0};
    HMONITOR mon = MonitorFromPoint(pt_zero, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO mi{sizeof(mi)};
    if (mon && GetMonitorInfoW(mon, &mi)) {
      work = mi.rcWork;
    } else {
      SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    }

    const int x = work.left + ((work.right - work.left) - win_w) / 2;
    const bool is_bottom = payload.position == "bottomCenter";
    const int slide_px = static_cast<int>((1.0f - anim_progress) * 28.0f);
    const int y = is_bottom
                      ? (work.bottom - win_h - 6 + slide_px)
                      : (work.top + 6 - slide_px);

    HDC screen_dc = GetDC(nullptr);
    HDC mem_dc = CreateCompatibleDC(screen_dc);
    BITMAPINFO bmi{};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = win_w;
    bmi.bmiHeader.biHeight = -win_h;  // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    void* bits = nullptr;
    HBITMAP dib = CreateDIBSection(screen_dc, &bmi, DIB_RGB_COLORS, &bits,
                                   nullptr, 0);
    HGDIOBJ old_bmp = SelectObject(mem_dc, dib);

    RECT bind_rc{0, 0, win_w, win_h};
    if (SUCCEEDED(rt->BindDC(mem_dc, &bind_rc))) {
      rt->BeginDraw();
      rt->Clear(D2D1::ColorF(0, 0, 0, 0));

      const float alpha = std::clamp(anim_progress, 0.0f, 1.0f);
      const D2D1_RECT_F pill_rc = D2D1::RectF(
          static_cast<float>(kHaloPad), static_cast<float>(kHaloPad),
          static_cast<float>(kHaloPad + pill_w),
          static_cast<float>(kHaloPad + kPillHeight));
      const float radius = static_cast<float>(kPillHeight) * 0.5f;
      D2D1_ROUNDED_RECT rrect{pill_rc, radius, radius};

      // Ambient outer accent glow
      ID2D1SolidColorBrush* halo_brush = nullptr;
      rt->CreateSolidColorBrush(
          ArgbToColorF(payload.accent_argb, 0.24f * alpha), &halo_brush);
      if (halo_brush) {
        D2D1_ROUNDED_RECT outer{
            D2D1::RectF(pill_rc.left - 3.0f, pill_rc.top - 3.0f,
                        pill_rc.right + 3.0f, pill_rc.bottom + 3.0f),
            radius + 3.0f, radius + 3.0f};
        rt->DrawRoundedRectangle(outer, halo_brush, 4.5f);
        halo_brush->Release();
      }

      // Frosted dark glass fill + glowing specular border
      ID2D1SolidColorBrush* bg_brush = nullptr;
      rt->CreateSolidColorBrush(
          D2D1::ColorF(0.082f, 0.088f, 0.122f, 0.92f * alpha), &bg_brush);
      if (bg_brush) {
        rt->FillRoundedRectangle(rrect, bg_brush);
        bg_brush->Release();
      }

      ID2D1SolidColorBrush* rim_brush = nullptr;
      rt->CreateSolidColorBrush(
          ArgbToColorF(payload.accent_argb, 0.85f * alpha), &rim_brush);
      if (rim_brush) {
        rt->DrawRoundedRectangle(rrect, rim_brush, 1.75f);
        rim_brush->Release();
      }

      // Thumbnail / accent avatar on left
      const float av_x = pill_rc.left + 16.0f;
      const float av_y = pill_rc.top + (kPillHeight - 36.0f) * 0.5f;
      const D2D1_RECT_F av_rc =
          D2D1::RectF(av_x, av_y, av_x + 36.0f, av_y + 36.0f);
      if (thumb_wic) {
        ID2D1Bitmap* d2d_bmp = nullptr;
        if (SUCCEEDED(rt->CreateBitmapFromWicBitmap(thumb_wic, nullptr,
                                                    &d2d_bmp)) &&
            d2d_bmp) {
          rt->DrawBitmap(d2d_bmp, av_rc, alpha);
          d2d_bmp->Release();
        }
      } else {
        ID2D1SolidColorBrush* orb_brush = nullptr;
        rt->CreateSolidColorBrush(
            ArgbToColorF(payload.accent_argb, 0.30f * alpha), &orb_brush);
        if (orb_brush) {
          rt->FillRoundedRectangle(D2D1::RoundedRect(av_rc, 11.0f, 11.0f),
                                   orb_brush);
          orb_brush->Release();
        }
      }

      // Right-aligned action buttons
      button_rects.clear();
      float btn_cursor_right = pill_rc.right - 14.0f;
      for (auto it = payload.buttons.rbegin(); it != payload.buttons.rend();
           ++it) {
        float bw = it->label.size() <= 2 ? 28.0f : 72.0f;
        float bh = 28.0f;
        D2D1_RECT_F brc = D2D1::RectF(
            btn_cursor_right - bw,
            pill_rc.top + (kPillHeight - bh) * 0.5f, btn_cursor_right,
            pill_rc.top + (kPillHeight + bh) * 0.5f);
        ButtonHitRect hrec;
        hrec.action = it->action;
        hrec.rect = brc;
        hrec.primary = it->primary;
        hrec.label = it->label;
        button_rects.push_back(std::move(hrec));

        ID2D1SolidColorBrush* bfill = nullptr;
        rt->CreateSolidColorBrush(
            it->primary ? ArgbToColorF(payload.accent_argb, alpha)
                        : D2D1::ColorF(1.0f, 1.0f, 1.0f, 0.14f * alpha),
            &bfill);
        if (bfill) {
          rt->FillRoundedRectangle(D2D1::RoundedRect(brc, 14.0f, 14.0f), bfill);
          bfill->Release();
        }

        ID2D1SolidColorBrush* btxt = nullptr;
        rt->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, alpha), &btxt);
        if (btxt && btn_fmt) {
          rt->DrawTextW(it->label.c_str(),
                        static_cast<UINT32>(it->label.size()), btn_fmt, brc,
                        btxt);
          btxt->Release();
        }
        btn_cursor_right = brc.left - 6.0f;
      }

      // Title & subtitle + optional progress bar
      const float text_left = av_rc.right + 12.0f;
      const float text_right =
          std::max(text_left + 40.0f, btn_cursor_right - 4.0f);

      ID2D1SolidColorBrush* title_brush = nullptr;
      rt->CreateSolidColorBrush(D2D1::ColorF(1.0f, 1.0f, 1.0f, alpha),
                                &title_brush);
      if (title_brush && title_fmt) {
        D2D1_RECT_F trc = D2D1::RectF(text_left, pill_rc.top + 12.0f,
                                      text_right, pill_rc.top + 32.0f);
        rt->DrawTextW(payload.title.c_str(),
                      static_cast<UINT32>(payload.title.size()), title_fmt, trc,
                      title_brush);
        title_brush->Release();
      }

      if (payload.has_progress) {
        const float bar_top = pill_rc.top + 42.0f;
        D2D1_RECT_F track =
            D2D1::RectF(text_left, bar_top, text_right, bar_top + 5.0f);
        ID2D1SolidColorBrush* trk_brush = nullptr;
        rt->CreateSolidColorBrush(
            D2D1::ColorF(1.0f, 1.0f, 1.0f, 0.18f * alpha), &trk_brush);
        if (trk_brush) {
          rt->FillRoundedRectangle(D2D1::RoundedRect(track, 2.5f, 2.5f),
                                   trk_brush);
          trk_brush->Release();
        }
        float pct =
            static_cast<float>(std::clamp(payload.progress, 0.05, 1.0));
        D2D1_RECT_F fill = D2D1::RectF(
            text_left, bar_top, text_left + (text_right - text_left) * pct,
            bar_top + 5.0f);
        ID2D1SolidColorBrush* fil_brush = nullptr;
        rt->CreateSolidColorBrush(
            ArgbToColorF(payload.accent_argb, alpha), &fil_brush);
        if (fil_brush) {
          rt->FillRoundedRectangle(D2D1::RoundedRect(fill, 2.5f, 2.5f),
                                   fil_brush);
          fil_brush->Release();
        }
      } else {
        ID2D1SolidColorBrush* sub_brush = nullptr;
        rt->CreateSolidColorBrush(D2D1::ColorF(0.82f, 0.85f, 0.92f, alpha),
                                  &sub_brush);
        if (sub_brush && sub_fmt) {
          D2D1_RECT_F src = D2D1::RectF(text_left, pill_rc.top + 34.0f,
                                        text_right, pill_rc.top + 54.0f);
          rt->DrawTextW(payload.subtitle.c_str(),
                        static_cast<UINT32>(payload.subtitle.size()), sub_fmt,
                        src, sub_brush);
          sub_brush->Release();
        }
      }

      rt->EndDraw();
    }

    POINT pt_dst{x, y};
    SIZE sz_wnd{win_w, win_h};
    POINT pt_src{0, 0};
    BLENDFUNCTION bf{};
    bf.BlendOp = AC_SRC_OVER;
    bf.SourceConstantAlpha = 255;
    bf.AlphaFormat = AC_SRC_ALPHA;

    SetWindowPos(hwnd, HWND_TOPMOST, x, y, win_w, win_h,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
    UpdateLayeredWindow(hwnd, screen_dc, &pt_dst, &sz_wnd, mem_dc, &pt_src, 0,
                        &bf, ULW_ALPHA);

    SelectObject(mem_dc, old_bmp);
    DeleteObject(dib);
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
  }

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                  LPARAM lparam) {
    auto* self = reinterpret_cast<Impl*>(
        GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (msg == WM_NCCREATE) {
      auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
      self = reinterpret_cast<Impl*>(cs->lpCreateParams);
      SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(self));
      return TRUE;
    }
    if (!self) return DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
      case WM_TIMER:
        if (wparam == kAnimTimerId) {
          float diff = self->anim_target - self->anim_progress;
          if (std::fabs(diff) < 0.02f) {
            self->anim_progress = self->anim_target;
            KillTimer(hwnd, kAnimTimerId);
            if (self->anim_target <= 0.0f) {
              ShowWindow(hwnd, SW_HIDE);
              self->visible = false;
              return 0;
            }
          } else {
            self->anim_progress += diff * 0.28f;
          }
          self->RenderLayeredFrame();
          return 0;
        }
        break;

      case WM_LBUTTONUP: {
        float px = static_cast<float>(LOWORD(lparam));
        float py = static_cast<float>(HIWORD(lparam));
        for (const auto& btn : self->button_rects) {
          if (px >= btn.rect.left && px <= btn.rect.right &&
              py >= btn.rect.top && py <= btn.rect.bottom) {
            if (self->on_action) self->on_action(btn.action);
            return 0;
          }
        }
        if (self->on_action) self->on_action("open_app");
        return 0;
      }

      case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
  }

  void EnsureWindow() {
    if (hwnd) return;
    HINSTANCE hinst = GetModuleHandleW(nullptr);
    if (!class_registered) {
      WNDCLASSEXW wc{};
      wc.cbSize = sizeof(wc);
      wc.lpfnWndProc = Impl::WndProc;
      wc.hInstance = hinst;
      wc.lpszClassName = kIslandClassName;
      wc.hCursor = LoadCursorW(nullptr, IDC_HAND);
      RegisterClassExW(&wc);
      class_registered = true;
    }
    hwnd = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_NOACTIVATE,
        kIslandClassName, L"MaterialDrop Island", WS_POPUP, 0, 0, 320, 96,
        nullptr, nullptr, hinst, this);
  }
};

DynamicIslandWin::DynamicIslandWin(ActionCallback on_action)
    : impl_(std::make_unique<Impl>()) {
  impl_->on_action = std::move(on_action);
}

DynamicIslandWin::~DynamicIslandWin() {
  Destroy();
}

void DynamicIslandWin::ShowOrUpdate(const DynamicIslandPayloadWin& payload) {
  impl_->EnsureResources();
  impl_->EnsureWindow();
  if (!impl_->hwnd) return;

  if (payload.thumbnail_png != impl_->payload.thumbnail_png) {
    impl_->ReleaseThumb();
    if (!payload.thumbnail_png.empty()) {
      impl_->thumb_wic =
          DecodeThumbnailFromPng(impl_->wic, payload.thumbnail_png);
    }
  }
  impl_->payload = payload;
  impl_->visible = true;
  impl_->anim_target = 1.0f;
  SetTimer(impl_->hwnd, kAnimTimerId, 16, nullptr);
  impl_->RenderLayeredFrame();
}

void DynamicIslandWin::Hide() {
  if (!impl_->hwnd || !impl_->visible) return;
  impl_->anim_target = 0.0f;
  SetTimer(impl_->hwnd, kAnimTimerId, 16, nullptr);
}

void DynamicIslandWin::Destroy() {
  if (impl_->hwnd) {
    KillTimer(impl_->hwnd, kAnimTimerId);
    DestroyWindow(impl_->hwnd);
    impl_->hwnd = nullptr;
  }
  impl_->visible = false;
}

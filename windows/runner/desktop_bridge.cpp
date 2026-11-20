#include "desktop_bridge.h"

#include <shellapi.h>
#include <shlobj.h>
#include <wincodec.h>

#include <algorithm>
#include <cstring>
#include <fstream>
#include <vector>

#include "resource.h"

namespace {

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return {};
  int len = MultiByteToWideChar(CP_UTF8, 0, s.c_str(),
                                static_cast<int>(s.size()), nullptr, 0);
  if (len <= 0) return {};
  std::wstring out(static_cast<size_t>(len), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()),
                      out.data(), len);
  return out;
}

std::string WideToUtf8(const std::wstring& s) {
  if (s.empty()) return {};
  int len = WideCharToMultiByte(CP_UTF8, 0, s.c_str(),
                                static_cast<int>(s.size()), nullptr, 0,
                                nullptr, nullptr);
  if (len <= 0) return {};
  std::string out(static_cast<size_t>(len), '\0');
  WideCharToMultiByte(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()),
                      out.data(), len, nullptr, nullptr);
  return out;
}

std::string GetStringArg(const flutter::EncodableMap* map, const char* key,
                         const std::string& fallback = "") {
  if (!map) return fallback;
  auto it = map->find(flutter::EncodableValue(key));
  if (it != map->end() && std::holds_alternative<std::string>(it->second)) {
    return std::get<std::string>(it->second);
  }
  return fallback;
}

bool GetBoolArg(const flutter::EncodableMap* map, const char* key,
                bool fallback) {
  if (!map) return fallback;
  auto it = map->find(flutter::EncodableValue(key));
  if (it != map->end() && std::holds_alternative<bool>(it->second)) {
    return std::get<bool>(it->second);
  }
  return fallback;
}

void CopyWideTruncated(wchar_t* dest, size_t cap, const std::wstring& src) {
  if (cap == 0) return;
  size_t to_copy = std::min(cap - 1, src.size());
  if (to_copy > 0) {
    wcsncpy_s(dest, cap, src.c_str(), to_copy);
  }
  dest[to_copy] = L'\0';
}

enum TrayMenuCmd : UINT {
  kCmdOpen = 1001,
  kCmdSend = 1002,
  kCmdDownloads = 1003,
  kCmdAutoAccept = 1004,
  kCmdSounds = 1005,
  kCmdExit = 1006,
};

}  // namespace

DesktopBridge::DesktopBridge(HWND hwnd, flutter::BinaryMessenger* messenger)
    : hwnd_(hwnd) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "dev.materialdrop.flutter/desktop",
      &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HandleMethodCall(call, std::move(result));
      });

  proximity_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "dev.materialdrop.flutter/proximity",
          &flutter::StandardMethodCodec::GetInstance());

  proximity_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HandleProximityMethodCall(call, std::move(result));
      });

  ble_win_ = std::make_unique<BleProximityWin>(
      [hwnd_copy = hwnd_](const BlePeerDiscoveryWin& peer) {
        auto* heap_peer = new BlePeerDiscoveryWin(peer);
        if (!PostMessage(hwnd_copy, kBlePeerMessage, 0,
                         reinterpret_cast<LPARAM>(heap_peer))) {
          delete heap_peer;
        }
      });
}

DesktopBridge::~DesktopBridge() {
  Cleanup();
}

void DesktopBridge::Cleanup() {
  if (ble_win_) {
    ble_win_->StopDiscovery();
  }
  if (tray_created_) {
    NOTIFYICONDATAW nid{};
    nid.cbSize = sizeof(nid);
    nid.hWnd = hwnd_;
    nid.uID = 1;
    Shell_NotifyIconW(NIM_DELETE, &nid);
    tray_created_ = false;
  }
}

std::optional<LRESULT> DesktopBridge::HandleWindowMessage(HWND hwnd,
                                                          UINT message,
                                                          WPARAM wparam,
                                                          LPARAM lparam) {
  if (message == WM_CLOSE && minimize_to_tray_ && !quitting_) {
    ShowWindow(hwnd, SW_HIDE);
    return 0;
  }

  if (message == kBlePeerMessage) {
    std::unique_ptr<BlePeerDiscoveryWin> peer(
        reinterpret_cast<BlePeerDiscoveryWin*>(lparam));
    if (peer && proximity_channel_) {
      flutter::EncodableMap map;
      map[flutter::EncodableValue("type")] =
          flutter::EncodableValue("blePeerFound");
      map[flutter::EncodableValue("bleAddress")] =
          flutter::EncodableValue(peer->address);
      map[flutter::EncodableValue("ephemeralId")] =
          flutter::EncodableValue(peer->ephemeral_id);
      map[flutter::EncodableValue("name")] =
          flutter::EncodableValue(peer->name);
      map[flutter::EncodableValue("port")] =
          flutter::EncodableValue(peer->port);
      map[flutter::EncodableValue("capabilities")] =
          flutter::EncodableValue(peer->capabilities);
      map[flutter::EncodableValue("rssi")] =
          flutter::EncodableValue(peer->rssi);
      map[flutter::EncodableValue("proximityZone")] =
          flutter::EncodableValue(peer->proximity_zone);
      proximity_channel_->InvokeMethod(
          "onProximityEvent",
          std::make_unique<flutter::EncodableValue>(std::move(map)));
    }
    return 0;
  }

  if (message == kTrayCallbackMessage) {
    UINT ev = LOWORD(lparam);
    if (ev == WM_LBUTTONUP || ev == WM_LBUTTONDBLCLK) {
      ShowWindow(hwnd_, SW_SHOW);
      ShowWindow(hwnd_, SW_RESTORE);
      SetForegroundWindow(hwnd_);
      if (channel_) {
        channel_->InvokeMethod(
            "onTrayAction",
            std::make_unique<flutter::EncodableValue>("open"));
      }
      return 0;
    }
    if (ev == WM_RBUTTONUP || ev == WM_CONTEXTMENU) {
      ShowTrayContextMenu();
      return 0;
    }
  }

  return std::nullopt;
}

void DesktopBridge::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  const std::string& method = call.method_name();

  if (method == "initTray") {
    InitOrUpdateTray(args, true);
    if (GetBoolArg(args, "startHidden", false)) {
      ShowWindow(hwnd_, SW_HIDE);
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "updateTrayState") {
    InitOrUpdateTray(args, false);
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "showWindow") {
    ShowWindow(hwnd_, SW_SHOW);
    ShowWindow(hwnd_, SW_RESTORE);
    SetForegroundWindow(hwnd_);
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "hideWindow") {
    ShowWindow(hwnd_, SW_HIDE);
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "setWindowTitle") {
    std::string title = GetStringArg(args, "title", "MaterialDrop");
    SetWindowTextW(hwnd_, Utf8ToWide(title).c_str());
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "isWindowVisible") {
    BOOL vis = IsWindowVisible(hwnd_) && !IsIconic(hwnd_);
    result->Success(flutter::EncodableValue(vis != FALSE));
    return;
  }

  if (method == "isFullscreenGameRunning") {
    QUERY_USER_NOTIFICATION_STATE state = QUNS_ACCEPTS_NOTIFICATIONS;
    bool is_game = false;
    if (SUCCEEDED(SHQueryUserNotificationState(&state))) {
      is_game = (state == QUNS_RUNNING_D3D_FULL_SCREEN);
    }
    result->Success(flutter::EncodableValue(is_game));
    return;
  }

  if (method == "showNotification") {
    ShowBalloonNotification(GetStringArg(args, "title", "MaterialDrop"),
                            GetStringArg(args, "body", ""));
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "readClipboard") {
    std::string temp_dir = GetStringArg(args, "tempDir", "");
    result->Success(flutter::EncodableValue(ReadClipboard(temp_dir)));
    return;
  }

  if (method == "writeImageToClipboard") {
    std::string path = GetStringArg(args, "path", "");
    result->Success(flutter::EncodableValue(WriteImageToClipboard(path)));
    return;
  }

  if (method == "quitApp") {
    quitting_ = true;
    Cleanup();
    result->Success(flutter::EncodableValue(true));
    PostMessage(hwnd_, WM_CLOSE, 0, 0);
    return;
  }

  result->NotImplemented();
}

void DesktopBridge::InitOrUpdateTray(const flutter::EncodableMap* args,
                                     bool init) {
  if (args) {
    label_open_ = Utf8ToWide(GetStringArg(args, "open", "Open MaterialDrop"));
    label_send_ = Utf8ToWide(GetStringArg(args, "send", "Send Files..."));
    label_downloads_ =
        Utf8ToWide(GetStringArg(args, "downloads", "Open Downloads"));
    label_auto_accept_ =
        Utf8ToWide(GetStringArg(args, "autoAccept", "Auto-accept"));
    label_sounds_ = Utf8ToWide(GetStringArg(args, "sounds", "Sounds"));
    label_exit_ = Utf8ToWide(GetStringArg(args, "exit", "Exit"));
    tooltip_ = Utf8ToWide(GetStringArg(args, "tooltip", "MaterialDrop"));
    auto_accept_ = GetBoolArg(args, "autoAccept", auto_accept_);
    sounds_enabled_ = GetBoolArg(args, "sounds", sounds_enabled_);
    minimize_to_tray_ = GetBoolArg(args, "minimizeToTray", minimize_to_tray_);
  }

  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = hwnd_;
  nid.uID = 1;
  nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  nid.uCallbackMessage = kTrayCallbackMessage;
  nid.hIcon =
      LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  CopyWideTruncated(nid.szTip, sizeof(nid.szTip) / sizeof(wchar_t), tooltip_);

  if (!tray_created_) {
    if (Shell_NotifyIconW(NIM_ADD, &nid)) {
      tray_created_ = true;
      nid.uVersion = NOTIFYICON_VERSION_4;
      Shell_NotifyIconW(NIM_SETVERSION, &nid);
    }
  } else if (!init) {
    Shell_NotifyIconW(NIM_MODIFY, &nid);
  }
}

void DesktopBridge::ShowTrayContextMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;

  AppendMenuW(menu, MF_STRING, kCmdOpen, label_open_.c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kCmdSend, label_send_.c_str());
  AppendMenuW(menu, MF_STRING, kCmdDownloads, label_downloads_.c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(
      menu, MF_STRING | (auto_accept_ ? MF_CHECKED : MF_UNCHECKED),
      kCmdAutoAccept, label_auto_accept_.c_str());
  AppendMenuW(
      menu, MF_STRING | (sounds_enabled_ ? MF_CHECKED : MF_UNCHECKED),
      kCmdSounds, label_sounds_.c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kCmdExit, label_exit_.c_str());

  POINT pt{};
  GetCursorPos(&pt);
  SetForegroundWindow(hwnd_);
  UINT cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY,
                            pt.x, pt.y, 0, hwnd_, nullptr);
  PostMessage(hwnd_, WM_NULL, 0, 0);
  DestroyMenu(menu);

  if (cmd == 0 || !channel_) return;

  const char* action = nullptr;
  switch (cmd) {
    case kCmdOpen:
      ShowWindow(hwnd_, SW_SHOW);
      ShowWindow(hwnd_, SW_RESTORE);
      SetForegroundWindow(hwnd_);
      action = "open";
      break;
    case kCmdSend:
      ShowWindow(hwnd_, SW_SHOW);
      ShowWindow(hwnd_, SW_RESTORE);
      SetForegroundWindow(hwnd_);
      action = "send";
      break;
    case kCmdDownloads:
      action = "downloads";
      break;
    case kCmdAutoAccept:
      action = "toggleAutoAccept";
      break;
    case kCmdSounds:
      action = "toggleSounds";
      break;
    case kCmdExit:
      quitting_ = true;
      Cleanup();
      action = "exit";
      break;
    default:
      break;
  }

  if (action != nullptr) {
    channel_->InvokeMethod(
        "onTrayAction",
        std::make_unique<flutter::EncodableValue>(std::string(action)));
  }
}

void DesktopBridge::ShowBalloonNotification(const std::string& title,
                                            const std::string& body) {
  if (!tray_created_) {
    InitOrUpdateTray(nullptr, true);
  }
  if (!tray_created_) return;

  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = hwnd_;
  nid.uID = 1;
  nid.uFlags = NIF_INFO;
  nid.dwInfoFlags = NIIF_INFO | NIIF_NOSOUND;
  CopyWideTruncated(nid.szInfoTitle,
                    sizeof(nid.szInfoTitle) / sizeof(wchar_t),
                    Utf8ToWide(title));
  CopyWideTruncated(nid.szInfo, sizeof(nid.szInfo) / sizeof(wchar_t),
                    Utf8ToWide(body));
  Shell_NotifyIconW(NIM_MODIFY, &nid);
}

flutter::EncodableMap DesktopBridge::ReadClipboard(
    const std::string& temp_dir) {
  flutter::EncodableMap out;
  out[flutter::EncodableValue("type")] = flutter::EncodableValue("empty");

  if (!OpenClipboard(hwnd_)) {
    return out;
  }

  if (IsClipboardFormatAvailable(CF_HDROP)) {
    HANDLE hDrop = GetClipboardData(CF_HDROP);
    if (hDrop) {
      HDROP drop = static_cast<HDROP>(GlobalLock(hDrop));
      if (drop) {
        UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
        flutter::EncodableList paths;
        for (UINT i = 0; i < count; ++i) {
          UINT len = DragQueryFileW(drop, i, nullptr, 0);
          if (len > 0) {
            std::wstring buf(len + 1, L'\0');
            DragQueryFileW(drop, i, buf.data(), len + 1);
            buf.resize(len);
            paths.push_back(flutter::EncodableValue(WideToUtf8(buf)));
          }
        }
        GlobalUnlock(hDrop);
        if (!paths.empty()) {
          CloseClipboard();
          out[flutter::EncodableValue("type")] =
              flutter::EncodableValue("files");
          out[flutter::EncodableValue("paths")] =
              flutter::EncodableValue(std::move(paths));
          return out;
        }
      }
    }
  }

  if (IsClipboardFormatAvailable(CF_DIB) && !temp_dir.empty()) {
    HANDLE hDib = GetClipboardData(CF_DIB);
    if (hDib) {
      SIZE_T dib_size = GlobalSize(hDib);
      const uint8_t* ptr = static_cast<const uint8_t*>(GlobalLock(hDib));
      if (ptr && dib_size >= sizeof(BITMAPINFOHEADER)) {
        const auto* bih = reinterpret_cast<const BITMAPINFOHEADER*>(ptr);
        DWORD palette_colors = bih->biClrUsed;
        if (palette_colors == 0 && bih->biBitCount <= 8) {
          palette_colors = 1u << bih->biBitCount;
        }
        DWORD bitfields_bytes =
            (bih->biCompression == BI_BITFIELDS && bih->biSize == 40) ? 12u
                                                                      : 0u;
        DWORD header_bytes =
            bih->biSize + palette_colors * 4u + bitfields_bytes;

        BITMAPFILEHEADER bfh{};
        bfh.bfType = 0x4D42;  // 'BM'
        bfh.bfSize = static_cast<DWORD>(sizeof(bfh) + dib_size);
        bfh.bfOffBits = static_cast<DWORD>(sizeof(bfh) + header_bytes);

        std::string out_path =
            temp_dir + "/clipboard_" +
            std::to_string(GetTickCount64()) + ".bmp";
        std::ofstream ofs(Utf8ToWide(out_path), std::ios::binary);
        if (ofs.is_open()) {
          ofs.write(reinterpret_cast<const char*>(&bfh), sizeof(bfh));
          ofs.write(reinterpret_cast<const char*>(ptr),
                    static_cast<std::streamsize>(dib_size));
          ofs.close();
          GlobalUnlock(hDib);
          CloseClipboard();
          out[flutter::EncodableValue("type")] =
              flutter::EncodableValue("imageFile");
          out[flutter::EncodableValue("path")] =
              flutter::EncodableValue(out_path);
          return out;
        }
      }
      if (ptr) GlobalUnlock(hDib);
    }
  }

  if (IsClipboardFormatAvailable(CF_UNICODETEXT)) {
    HANDLE hText = GetClipboardData(CF_UNICODETEXT);
    if (hText) {
      const wchar_t* wptr = static_cast<const wchar_t*>(GlobalLock(hText));
      if (wptr) {
        std::string text = WideToUtf8(std::wstring(wptr));
        GlobalUnlock(hText);
        if (!text.empty()) {
          CloseClipboard();
          out[flutter::EncodableValue("type")] =
              flutter::EncodableValue("text");
          out[flutter::EncodableValue("text")] = flutter::EncodableValue(text);
          return out;
        }
      }
    }
  }

  CloseClipboard();
  return out;
}

bool DesktopBridge::WriteImageToClipboard(const std::string& file_path) {
  if (file_path.empty()) return false;
  std::wstring wpath = Utf8ToWide(file_path);

  IWICImagingFactory* factory = nullptr;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&factory));
  if (FAILED(hr) || !factory) return false;

  IWICBitmapDecoder* decoder = nullptr;
  IWICBitmapFrameDecode* frame = nullptr;
  IWICFormatConverter* converter = nullptr;
  bool ok = false;

  hr = factory->CreateDecoderFromFilename(wpath.c_str(), nullptr,
                                          GENERIC_READ,
                                          WICDecodeMetadataCacheOnLoad,
                                          &decoder);
  if (SUCCEEDED(hr) && decoder) {
    hr = decoder->GetFrame(0, &frame);
  }
  if (SUCCEEDED(hr) && frame) {
    hr = factory->CreateFormatConverter(&converter);
  }
  if (SUCCEEDED(hr) && converter) {
    hr = converter->Initialize(frame, GUID_WICPixelFormat32bppBGRA,
                               WICBitmapDitherTypeNone, nullptr, 0.0,
                               WICBitmapPaletteTypeCustom);
  }
  if (SUCCEEDED(hr) && converter) {
    UINT w = 0, h = 0;
    if (SUCCEEDED(converter->GetSize(&w, &h)) && w > 0 && h > 0) {
      const UINT stride = w * 4;
      const UINT img_size = stride * h;
      std::vector<BYTE> top_down(img_size);
      if (SUCCEEDED(converter->CopyPixels(nullptr, stride, img_size,
                                          top_down.data()))) {
        SIZE_T total = sizeof(BITMAPINFOHEADER) + img_size;
        HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, total);
        if (hMem) {
          BYTE* dst = static_cast<BYTE*>(GlobalLock(hMem));
          if (dst) {
            BITMAPINFOHEADER bih{};
            bih.biSize = sizeof(BITMAPINFOHEADER);
            bih.biWidth = static_cast<LONG>(w);
            bih.biHeight = static_cast<LONG>(h);  // bottom-up CF_DIB
            bih.biPlanes = 1;
            bih.biBitCount = 32;
            bih.biCompression = BI_RGB;
            bih.biSizeImage = img_size;
            std::memcpy(dst, &bih, sizeof(bih));

            BYTE* pixels = dst + sizeof(BITMAPINFOHEADER);
            for (UINT y = 0; y < h; ++y) {
              const BYTE* src_row = top_down.data() + (h - 1 - y) * stride;
              std::memcpy(pixels + y * stride, src_row, stride);
            }
            GlobalUnlock(hMem);

            if (OpenClipboard(hwnd_)) {
              EmptyClipboard();
              if (SetClipboardData(CF_DIB, hMem) != nullptr) {
                ok = true;
              } else {
                GlobalFree(hMem);
              }
              CloseClipboard();
            } else {
              GlobalFree(hMem);
            }
          } else {
            GlobalFree(hMem);
          }
        }
      }
    }
  }

  if (converter) converter->Release();
  if (frame) frame->Release();
  if (decoder) decoder->Release();
  factory->Release();
  return ok;
}

void DesktopBridge::HandleProximityMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  const std::string& method = call.method_name();

  if (method == "getProximityStatus") {
    BleAdapterStatusWin st =
        ble_win_ ? ble_win_->GetStatus() : BleAdapterStatusWin{};
    flutter::EncodableMap ble;
    ble[flutter::EncodableValue("supported")] =
        flutter::EncodableValue(st.supported);
    ble[flutter::EncodableValue("adapterAvailable")] =
        flutter::EncodableValue(st.adapter_available);
    ble[flutter::EncodableValue("adapterEnabled")] =
        flutter::EncodableValue(st.adapter_enabled);
    ble[flutter::EncodableValue("permissionsGranted")] =
        flutter::EncodableValue(true);
    ble[flutter::EncodableValue("scanning")] =
        flutter::EncodableValue(st.scanning);
    ble[flutter::EncodableValue("advertising")] =
        flutter::EncodableValue(st.advertising);
    ble[flutter::EncodableValue("reason")] =
        flutter::EncodableValue(st.reason);

    flutter::EncodableMap out;
    out[flutter::EncodableValue("supported")] = flutter::EncodableValue(true);
    out[flutter::EncodableValue("ble")] =
        flutter::EncodableValue(std::move(ble));
    out[flutter::EncodableValue("nfcSupported")] =
        flutter::EncodableValue(false);
    out[flutter::EncodableValue("nfcEnabled")] =
        flutter::EncodableValue(false);
    out[flutter::EncodableValue("nfcReaderActive")] =
        flutter::EncodableValue(false);
    out[flutter::EncodableValue("wifiDirectSupported")] =
        flutter::EncodableValue(false);
    out[flutter::EncodableValue("wifiDirectPermissionsGranted")] =
        flutter::EncodableValue(false);
    result->Success(flutter::EncodableValue(std::move(out)));
    return;
  }

  if (method == "requestProximityPermissions" ||
      method == "updateSessionMetadata") {
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "startBleDiscovery") {
    int port = 53317;
    std::vector<uint8_t> eph(16, 0x42);
    if (args) {
      auto pit = args->find(flutter::EncodableValue("port"));
      if (pit != args->end() && std::holds_alternative<int>(pit->second)) {
        port = std::get<int>(pit->second);
      }
      auto eit = args->find(flutter::EncodableValue("ephemeralBytes"));
      if (eit != args->end() &&
          std::holds_alternative<std::vector<uint8_t>>(eit->second)) {
        eph = std::get<std::vector<uint8_t>>(eit->second);
      }
    }
    bool ok = ble_win_ ? ble_win_->StartDiscovery(port, eph) : false;
    flutter::EncodableMap res;
    res[flutter::EncodableValue("advertising")] = flutter::EncodableValue(ok);
    res[flutter::EncodableValue("scanning")] = flutter::EncodableValue(ok);
    result->Success(flutter::EncodableValue(std::move(res)));
    return;
  }

  if (method == "stopBleDiscovery") {
    if (ble_win_) ble_win_->StopDiscovery();
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "setNfcReaderEnabled" || method == "stopDirectWifiHost" ||
      method == "disconnectDirectWifi") {
    result->Success(flutter::EncodableValue(false));
    return;
  }

  result->NotImplemented();
}

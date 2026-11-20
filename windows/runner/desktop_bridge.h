#ifndef RUNNER_DESKTOP_BRIDGE_H_
#define RUNNER_DESKTOP_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <optional>
#include <string>

#include "ble_proximity_win.h"

class DesktopBridge {
 public:
  static constexpr UINT kTrayCallbackMessage = WM_APP + 100;
  static constexpr UINT kBlePeerMessage = WM_APP + 101;

  DesktopBridge(HWND hwnd, flutter::BinaryMessenger* messenger);
  ~DesktopBridge();

  std::optional<LRESULT> HandleWindowMessage(HWND hwnd, UINT message,
                                             WPARAM wparam, LPARAM lparam);
  void Cleanup();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleProximityMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void InitOrUpdateTray(const flutter::EncodableMap* args, bool init);
  void ShowTrayContextMenu();
  void ShowBalloonNotification(const std::string& title,
                               const std::string& body);
  flutter::EncodableMap ReadClipboard(const std::string& temp_dir);
  bool WriteImageToClipboard(const std::string& file_path);

  HWND hwnd_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      proximity_channel_;
  std::unique_ptr<BleProximityWin> ble_win_;
  bool tray_created_ = false;
  bool minimize_to_tray_ = true;
  bool auto_accept_ = false;
  bool sounds_enabled_ = true;
  bool quitting_ = false;

  std::wstring label_open_ = L"Open MaterialDrop";
  std::wstring label_send_ = L"Send Files...";
  std::wstring label_downloads_ = L"Open Downloads";
  std::wstring label_auto_accept_ = L"Auto-accept";
  std::wstring label_sounds_ = L"Sounds";
  std::wstring label_exit_ = L"Exit";
  std::wstring tooltip_ = L"MaterialDrop";
};

#endif  // RUNNER_DESKTOP_BRIDGE_H_

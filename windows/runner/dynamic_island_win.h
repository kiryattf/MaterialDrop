#ifndef RUNNER_DYNAMIC_ISLAND_WIN_H_
#define RUNNER_DYNAMIC_ISLAND_WIN_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

struct DynamicIslandButtonSpec {
  std::string action;
  std::wstring label;
  bool primary = false;
};

struct DynamicIslandPayloadWin {
  std::string mode;      // "peek", "offer", "progress", "completed"
  std::string position;  // "topCenter", "bottomCenter"
  std::wstring title;
  std::wstring subtitle;
  uint32_t accent_argb = 0xFF6750A4;
  double progress = 0.0;
  bool has_progress = false;
  std::vector<uint8_t> thumbnail_png;
  std::vector<DynamicIslandButtonSpec> buttons;
};

/// Borderless topmost layered Win32 Dynamic Island overlay rendered with
/// Direct2D/DirectWrite + WIC without stealing focus or adding a taskbar button.
class DynamicIslandWin {
 public:
  using ActionCallback = std::function<void(const std::string& action)>;

  explicit DynamicIslandWin(ActionCallback on_action);
  ~DynamicIslandWin();

  void ShowOrUpdate(const DynamicIslandPayloadWin& payload);
  void Hide();
  void Destroy();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_DYNAMIC_ISLAND_WIN_H_

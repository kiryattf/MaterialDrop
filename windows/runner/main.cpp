#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // Forward single-instance materialdrop:// links to any active MaterialDrop window.
  bool is_multi_instance = false;
  std::string deep_link_arg;
  for (const auto& arg : command_line_arguments) {
    if (arg == "--port" || arg.rfind("--port=", 0) == 0 ||
        arg == "--bind" || arg.rfind("--bind=", 0) == 0 ||
        arg == "--name" || arg.rfind("--name=", 0) == 0) {
      is_multi_instance = true;
    } else if (arg.rfind("materialdrop://", 0) == 0) {
      deep_link_arg = arg;
    }
  }
  if (!is_multi_instance && !deep_link_arg.empty()) {
    HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"MaterialDrop");
    if (existing != nullptr) {
      COPYDATASTRUCT cds{};
      cds.dwData = 0x4D445552;  // 'MDUR'
      cds.cbData = static_cast<DWORD>(deep_link_arg.size() + 1);
      cds.lpData = const_cast<char*>(deep_link_arg.c_str());
      ::SendMessageW(existing, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&cds));
      ::CoUninitialize();
      return EXIT_SUCCESS;
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1040, 700);
  if (!window.Create(L"MaterialDrop", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}

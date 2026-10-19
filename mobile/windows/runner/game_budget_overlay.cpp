#include "game_budget_overlay.h"

#include <windows.h>
#include <algorithm>
#include <cstdint>
#include <limits>
#include <string>

namespace {

constexpr wchar_t kOverlayClass[] = L"FocusFenseGameBudgetOverlay";
constexpr int kOverlayWidth = 270;
constexpr int kOverlayHeight = 40;
constexpr UINT_PTR kTimerId = 1;

struct OverlayState {
  HWND window = nullptr;
  DWORD game_pid = 0;
  int remaining_seconds = 0;
  std::wstring prefix;
};

OverlayState g_state;

std::wstring FormatRemaining() {
  const int seconds = std::max(0, g_state.remaining_seconds);
  const int minutes = seconds / 60;
  const int remainder = seconds % 60;
  wchar_t time[16]{};
  swprintf_s(time, L"%d:%02d", minutes, remainder);
  return g_state.prefix + time;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (length <= 0) return {};
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(),
                      static_cast<int>(value.size()), result.data(), length);
  return result;
}

void HideOverlay() {
  if (g_state.window && IsWindow(g_state.window)) {
    ShowWindow(g_state.window, SW_HIDE);
  }
}

void PositionOverGame() {
  if (!g_state.window) return;
  HWND foreground = GetForegroundWindow();
  DWORD pid = 0;
  if (foreground) GetWindowThreadProcessId(foreground, &pid);
  if (pid != g_state.game_pid) {
    HideOverlay();
    return;
  }

  RECT game_rect{};
  if (!GetWindowRect(foreground, &game_rect)) return;
  const int game_width = game_rect.right - game_rect.left;
  const int width = std::min(kOverlayWidth, std::max(180, game_width - 24));
  const int left = game_rect.left + (game_width - width) / 2;
  const int top = game_rect.top + 8;
  SetWindowPos(g_state.window, HWND_TOPMOST, left, top, width, kOverlayHeight,
               SWP_NOACTIVATE);
  ShowWindow(g_state.window, SW_SHOWNOACTIVATE);
}

LRESULT CALLBACK OverlayWindowProc(HWND window, UINT message, WPARAM wparam,
                                   LPARAM lparam) {
  switch (message) {
    case WM_NCHITTEST:
      return HTTRANSPARENT;
    case WM_TIMER: {
      if (wparam == kTimerId) {
        HWND foreground = GetForegroundWindow();
        DWORD pid = 0;
        if (foreground) GetWindowThreadProcessId(foreground, &pid);
        if (pid != g_state.game_pid) {
          HideOverlay();
        } else {
          if (g_state.remaining_seconds > 0) --g_state.remaining_seconds;
          PositionOverGame();
          InvalidateRect(window, nullptr, TRUE);
        }
      }
      return 0;
    }
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      HDC dc = BeginPaint(window, &paint);
      RECT bounds{};
      GetClientRect(window, &bounds);
      HBRUSH brush = CreateSolidBrush(RGB(20, 28, 42));
      HBRUSH previous = static_cast<HBRUSH>(SelectObject(dc, brush));
      HPEN pen = CreatePen(PS_SOLID, 1, RGB(72, 91, 118));
      HPEN old_pen = static_cast<HPEN>(SelectObject(dc, pen));
      RoundRect(dc, bounds.left, bounds.top, bounds.right, bounds.bottom, 18, 18);
      SelectObject(dc, previous);
      SelectObject(dc, old_pen);
      DeleteObject(brush);
      DeleteObject(pen);

      SetBkMode(dc, TRANSPARENT);
      SetTextColor(dc, RGB(235, 241, 250));
      HFONT font = CreateFontW(18, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
                               DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                               CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                               DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
      HFONT old_font = static_cast<HFONT>(SelectObject(dc, font));
      DrawTextW(dc, FormatRemaining().c_str(), -1, &bounds,
                DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
      SelectObject(dc, old_font);
      DeleteObject(font);
      EndPaint(window, &paint);
      return 0;
    }
    case WM_DESTROY:
      KillTimer(window, kTimerId);
      g_state.window = nullptr;
      return 0;
  }
  return DefWindowProc(window, message, wparam, lparam);
}

bool EnsureOverlayWindow() {
  if (g_state.window && IsWindow(g_state.window)) return true;

  static bool registered = false;
  if (!registered) {
    WNDCLASSEXW klass{};
    klass.cbSize = sizeof(klass);
    klass.hInstance = GetModuleHandle(nullptr);
    klass.lpfnWndProc = OverlayWindowProc;
    klass.lpszClassName = kOverlayClass;
    klass.hCursor = LoadCursor(nullptr, IDC_ARROW);
    if (!RegisterClassExW(&klass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      return false;
    }
    registered = true;
  }

  g_state.window = CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE |
          WS_EX_TOOLWINDOW,
      kOverlayClass, L"FocusFense game time", WS_POPUP, 0, 0, kOverlayWidth,
      kOverlayHeight, nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
  if (!g_state.window) return false;
  SetLayeredWindowAttributes(g_state.window, 0, 220, LWA_ALPHA);
  SetTimer(g_state.window, kTimerId, 1000, nullptr);
  return true;
}

const flutter::EncodableValue* FindValue(const flutter::EncodableMap& map,
                                         const char* key) {
  const auto found = map.find(flutter::EncodableValue(key));
  return found == map.end() ? nullptr : &found->second;
}

}  // namespace

GameBudgetOverlay::GameBudgetOverlay(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "com.sixvpnblocker.app/game_budget_overlay",
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

GameBudgetOverlay::~GameBudgetOverlay() {
  if (channel_) channel_->SetMethodCallHandler(nullptr);
  HideOverlay();
  if (g_state.window) DestroyWindow(g_state.window);
}

void GameBudgetOverlay::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "hide") {
    HideOverlay();
    result->Success();
    return;
  }
  if (call.method_name() != "show") {
    result->NotImplemented();
    return;
  }

  const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!map) {
    result->Error("invalid_arguments", "Expected overlay settings.");
    return;
  }
  const auto* label = FindValue(*map, "label");
  const auto* process_id = FindValue(*map, "processId");
  const auto* seconds = FindValue(*map, "remainingSeconds");
  if (!label || !process_id || !seconds ||
      !std::holds_alternative<std::string>(*label)) {
    result->Error("invalid_arguments", "Missing overlay label or game state.");
    return;
  }

  g_state.prefix = Utf8ToWide(std::get<std::string>(*label));
  if (const auto* process_id_32 = std::get_if<int32_t>(process_id)) {
    g_state.game_pid = static_cast<DWORD>(*process_id_32);
  } else if (const auto* process_id_64 = std::get_if<int64_t>(process_id)) {
    g_state.game_pid = static_cast<DWORD>(*process_id_64);
  }
  if (const auto* seconds_32 = std::get_if<int32_t>(seconds)) {
    g_state.remaining_seconds = std::max(0, *seconds_32);
  } else if (const auto* seconds_64 = std::get_if<int64_t>(seconds)) {
    g_state.remaining_seconds = static_cast<int>(
        std::clamp<int64_t>(*seconds_64, 0, std::numeric_limits<int>::max()));
  }
  if (g_state.game_pid == 0 || !EnsureOverlayWindow()) {
    result->Error("overlay_unavailable", "Could not create game overlay.");
    return;
  }
  PositionOverGame();
  InvalidateRect(g_state.window, nullptr, TRUE);
  DWORD foreground_pid = 0;
  const HWND foreground = GetForegroundWindow();
  if (foreground) GetWindowThreadProcessId(foreground, &foreground_pid);
  flutter::EncodableMap state;
  state[flutter::EncodableValue("windowCreated")] =
      flutter::EncodableValue(g_state.window != nullptr);
  state[flutter::EncodableValue("windowVisible")] =
      flutter::EncodableValue(IsWindowVisible(g_state.window) != FALSE);
  state[flutter::EncodableValue("foregroundPid")] =
      flutter::EncodableValue(static_cast<int32_t>(foreground_pid));
  state[flutter::EncodableValue("gamePid")] =
      flutter::EncodableValue(static_cast<int32_t>(g_state.game_pid));
  result->Success(flutter::EncodableValue(std::move(state)));
}

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef WINVER
#define WINVER 0x0A00
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <propsys.h>
#include <d2d1.h>
#include <dwrite.h>
#include <dwmapi.h>
#include <atomic>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

constexpr UINT finished = WM_APP + 1;
constexpr UINT cancelUpload = WM_APP + 2;
constexpr UINT uploadProgress = WM_APP + 3;
constexpr UINT connectionFailed = WM_APP + 4;
constexpr UINT_PTR pasteDeadline = 1;
constexpr UINT_PTR statusExpiry = 2;
constexpr UINT_PTR progressDelay = 3;
constexpr UINT hotkeyId = 1;
constexpr wchar_t title[] = L"ClipBridge";
constexpr wchar_t windowClass[] = L"ClipBridgeHotkeyWindow";
constexpr wchar_t progressClass[] = L"ClipBridgeProgressWindow";
constexpr wchar_t appId[] = L"ClipBridge.Desktop";

enum class TransferPhase {
    ReadingClipboard, Preparing, Encoding, Packing, Connecting, Uploading,
    ServerVerifying, Committed, InjectingPath, Finished, Cancelled, Failed,
    UnknownCommit
};

struct TransferEvent {
    std::uint64_t requestId{};
    TransferPhase phase{TransferPhase::Preparing};
    unsigned long long completedBytes{};
    unsigned long long totalBytes{};
    bool totalKnown{};
    std::wstring displayName;
    std::wstring safeMessage;
};

struct Upload {
    HWND target{};
    DWORD pid{};
    unsigned long long focusGeneration{};
    ULONGLONG started{};
    bool pasteCandidate{};
    DWORD clipboardSequence{};
    std::uint64_t requestId{};
    std::string path;
    std::wstring error;
    std::shared_ptr<std::atomic_bool> cancel;
};

HWND window;
HWINEVENTHOOK eventHook;
unsigned long long focusGeneration;
std::shared_ptr<std::atomic_bool> active;
std::atomic_bool closing{false};
std::shared_ptr<std::atomic_bool> startupConnect;
std::wstring terminal;
ULONGLONG pasteTimeoutMs = 8000;
HWND statusWindow;
HMONITOR statusMonitor;
std::wstring statusBody;
std::wstring displayName;
std::wstring byteLabel;
std::wstring phaseLabel;
unsigned long long completedBytes;
unsigned long long totalBytes;
bool totalKnown;
ID2D1Factory* d2dFactory;
IDWriteFactory* writeFactory;
IDWriteTextFormat* titleFormat;
IDWriteTextFormat* bodyFormat;
IDWriteTextFormat* smallFormat;
ID2D1HwndRenderTarget* renderTarget;
ID2D1SolidColorBrush* backgroundBrush;
ID2D1SolidColorBrush* foregroundBrush;
ID2D1SolidColorBrush* mutedBrush;
ID2D1SolidColorBrush* accentBrush;
ID2D1SolidColorBrush* trackBrush;
UINT currentDpi = 96;
std::uint64_t activeRequestId;
std::atomic_uint64_t nextRequestId{1};
bool statusWasShown;
bool progressDelayPending;
bool deadlineExpired;
HANDLE agentProcess;
HANDLE agentJob;
HANDLE agentInput;
HANDLE agentOutput;
std::mutex agentMutex;
std::string agentBuffer;

void notify(const wchar_t* message);
std::wstring utf8ToWide(const std::string& text);
std::string decodeBase64(const std::string& text);

void releaseRenderTarget() {
    if (backgroundBrush) { backgroundBrush->Release(); backgroundBrush = nullptr; }
    if (foregroundBrush) { foregroundBrush->Release(); foregroundBrush = nullptr; }
    if (mutedBrush) { mutedBrush->Release(); mutedBrush = nullptr; }
    if (accentBrush) { accentBrush->Release(); accentBrush = nullptr; }
    if (trackBrush) { trackBrush->Release(); trackBrush = nullptr; }
    if (renderTarget) { renderTarget->Release(); renderTarget = nullptr; }
}

bool createRenderTarget(HWND hwnd) {
    if (renderTarget) return true;
    RECT client{};
    GetClientRect(hwnd, &client);
    const auto width = std::max<LONG>(1, client.right - client.left);
    const auto height = std::max<LONG>(1, client.bottom - client.top);
    const auto size = D2D1::SizeU(static_cast<UINT32>(width), static_cast<UINT32>(height));
    if (FAILED(d2dFactory->CreateHwndRenderTarget(
            D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT,
                D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE),
                static_cast<float>(currentDpi), static_cast<float>(currentDpi)),
            D2D1::HwndRenderTargetProperties(hwnd, size, D2D1_PRESENT_OPTIONS_NONE), &renderTarget)))
        return false;
    if (FAILED(renderTarget->CreateSolidColorBrush(D2D1::ColorF(0x202124), &backgroundBrush)) ||
        FAILED(renderTarget->CreateSolidColorBrush(D2D1::ColorF(0xF3F4F6), &foregroundBrush)) ||
        FAILED(renderTarget->CreateSolidColorBrush(D2D1::ColorF(0xB8BEC8), &mutedBrush)) ||
        FAILED(renderTarget->CreateSolidColorBrush(D2D1::ColorF(0x7CB5FF), &accentBrush)) ||
        FAILED(renderTarget->CreateSolidColorBrush(D2D1::ColorF(0x424750), &trackBrush))) {
        releaseRenderTarget();
        return false;
    }
    return true;
}

void drawProgress(HWND hwnd) {
    if (!createRenderTarget(hwnd)) return;
    RECT client{};
    GetClientRect(hwnd, &client);
    const float scale = 96.0f / static_cast<float>(currentDpi);
    const float width = static_cast<float>(client.right) * scale;
    const float height = static_cast<float>(client.bottom) * scale;
    renderTarget->BeginDraw();
    renderTarget->Clear(D2D1::ColorF(0x202124));
    renderTarget->FillRoundedRectangle(D2D1::RoundedRect(
        D2D1::RectF(0, 0, width, height), 12, 12), backgroundBrush);
    renderTarget->FillEllipse(D2D1::Ellipse(D2D1::Point2F(22, 24), 4, 4), accentBrush);
    const auto line = phaseLabel.empty() ? statusBody : phaseLabel;
    renderTarget->DrawText(line.c_str(), static_cast<UINT32>(line.size()), titleFormat,
        D2D1::RectF(36, 12, width - 18, 36), foregroundBrush,
        D2D1_DRAW_TEXT_OPTIONS_CLIP);
    if (!displayName.empty()) {
        renderTarget->DrawText(displayName.c_str(), static_cast<UINT32>(displayName.size()), bodyFormat,
            D2D1::RectF(20, 42, width - 18, 64), mutedBrush,
            D2D1_DRAW_TEXT_OPTIONS_CLIP);
    }
    constexpr float horizontalMargin = 20;
    constexpr float barY = 76;
    renderTarget->FillRoundedRectangle(D2D1::RoundedRect(
        D2D1::RectF(horizontalMargin, barY, width - horizontalMargin, barY + 4), 2, 2), trackBrush);
    const auto barWidth = std::max(0.0f, width - horizontalMargin * 2);
    if (totalKnown && totalBytes > 0) {
        const auto ratio = std::min(1.0, static_cast<double>(completedBytes) / static_cast<double>(totalBytes));
        renderTarget->FillRoundedRectangle(D2D1::RoundedRect(
            D2D1::RectF(horizontalMargin, barY, horizontalMargin + static_cast<float>(barWidth * ratio), barY + 4), 2, 2), accentBrush);
    } else {
        renderTarget->FillRoundedRectangle(D2D1::RoundedRect(
            D2D1::RectF(horizontalMargin, barY, horizontalMargin + barWidth * 0.22f, barY + 4), 2, 2), accentBrush);
    }
    if (!byteLabel.empty()) {
        renderTarget->DrawText(byteLabel.c_str(), static_cast<UINT32>(byteLabel.size()), smallFormat,
            D2D1::RectF(horizontalMargin, 88, width - 18, height - 6), mutedBrush,
            D2D1_DRAW_TEXT_OPTIONS_CLIP);
    }
    if (renderTarget->EndDraw() == D2DERR_RECREATE_TARGET) releaseRenderTarget();
}

LRESULT CALLBACK progressWindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
    case WM_PAINT: {
        PAINTSTRUCT paint{};
        BeginPaint(hwnd, &paint);
        drawProgress(hwnd);
        EndPaint(hwnd, &paint);
        return 0;
    }
    case WM_SIZE:
        if (renderTarget) renderTarget->Resize(D2D1::SizeU(LOWORD(lParam), HIWORD(lParam)));
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
    case WM_DPICHANGED: {
        currentDpi = HIWORD(wParam);
        const auto suggested = reinterpret_cast<RECT*>(lParam);
        SetWindowPos(hwnd, nullptr, suggested->left, suggested->top,
            suggested->right - suggested->left, suggested->bottom - suggested->top,
            SWP_NOZORDER | SWP_NOACTIVATE);
        if (renderTarget) renderTarget->SetDpi(static_cast<float>(currentDpi), static_cast<float>(currentDpi));
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
    }
    case WM_DISPLAYCHANGE:
    case WM_THEMECHANGED:
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
    }
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

bool initializeProgressWindow(HINSTANCE instance) {
    if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &d2dFactory)) ||
        FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
            reinterpret_cast<IUnknown**>(&writeFactory)))) return false;
    if (FAILED(writeFactory->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_SEMI_BOLD,
            DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, 15.0f, L"en-us", &titleFormat)) ||
        FAILED(writeFactory->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, 15.0f, L"en-us", &bodyFormat)) ||
        FAILED(writeFactory->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, 11.0f, L"en-us", &smallFormat))) return false;
    titleFormat->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    bodyFormat->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    smallFormat->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    IDWriteInlineObject* ellipsis = nullptr;
    if (SUCCEEDED(writeFactory->CreateEllipsisTrimmingSign(smallFormat, &ellipsis))) {
        const DWRITE_TRIMMING trimming{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
        bodyFormat->SetTrimming(&trimming, ellipsis);
        smallFormat->SetTrimming(&trimming, ellipsis);
        ellipsis->Release();
    }
    WNDCLASSW cls{};
    cls.lpfnWndProc = progressWindowProc;
    cls.hInstance = instance;
    cls.lpszClassName = progressClass;
    if (!RegisterClassW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
    statusWindow = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST,
        progressClass, L"ClipBridge progress", WS_POPUP | WS_BORDER,
        0, 0, 360, 116, window, nullptr, instance, nullptr);
    if (!statusWindow) return false;
    currentDpi = GetDpiForWindow(statusWindow);
    const DWM_WINDOW_CORNER_PREFERENCE preference = DWMWCP_ROUND;
    DwmSetWindowAttribute(statusWindow, DWMWA_WINDOW_CORNER_PREFERENCE, &preference, sizeof(preference));
    return createRenderTarget(statusWindow);
}

bool showStatus(const std::wstring& text) {
    if (!statusWindow) return false;
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    if (!GetMonitorInfoW(statusMonitor, &monitor)) return false;
    const RECT area = monitor.rcWork;
    statusBody = text;
    const auto newline = statusBody.find(L"\r\n");
    if (newline != std::wstring::npos) statusBody = statusBody.substr(newline + 2);
    constexpr float widthDip = 344;
    constexpr float heightDip = 116;
    const LONG margin = MulDiv(16, currentDpi, 96);
    const LONG width = std::min<LONG>(MulDiv(static_cast<int>(widthDip), currentDpi, 96),
        std::max<LONG>(1, area.right - area.left - 2 * margin));
    const LONG height = std::min<LONG>(MulDiv(static_cast<int>(heightDip), currentDpi, 96),
        std::max<LONG>(1, area.bottom - area.top - 2 * margin));
    if (renderTarget) renderTarget->SetDpi(static_cast<float>(currentDpi), static_cast<float>(currentDpi));
    InvalidateRect(statusWindow, nullptr, FALSE);
    return SetWindowPos(statusWindow, HWND_TOPMOST, area.right - width - margin,
        area.bottom - height - margin, width, height,
        SWP_NOACTIVATE | SWP_SHOWWINDOW) != FALSE;
}

void refreshProgress() {
    if (deadlineExpired) phaseLabel = L"上传仍在继续；自动输入时限已过";
    if (statusWindow && IsWindowVisible(statusWindow)) {
        showStatus(L"ClipBridge\r\n" + phaseLabel);
    } else if (!closing && !progressDelayPending) {
        SetTimer(window, progressDelay, 300, nullptr);
        progressDelayPending = true;
    }
}

void hideStatus() {
    if (statusWindow) ShowWindow(statusWindow, SW_HIDE);
}

void showResult(const std::wstring& text, UINT duration = 5000) {
    KillTimer(window, progressDelay);
    progressDelayPending = false;
    phaseLabel = text;
    byteLabel.clear();
    totalKnown = false;
    if (!showStatus(L"ClipBridge\r\n" + text))
        notify(text.c_str());
    else {
        statusWasShown = true;
        SetTimer(window, statusExpiry, duration, nullptr);
    }
}

std::wstring modulePath() {
    wchar_t exe[32768];
    const DWORD n = GetModuleFileNameW(nullptr, exe, ARRAYSIZE(exe));
    return n && n < ARRAYSIZE(exe) ? std::wstring(exe, n) : L"";
}

std::wstring powershellPath() {
    wchar_t system[32768];
    const UINT length = GetSystemDirectoryW(system, ARRAYSIZE(system));
    if (!length || length >= ARRAYSIZE(system)) return {};
    return std::wstring(system, length) + L"\\WindowsPowerShell\\v1.0\\powershell.exe";
}

HRESULT registerNotificationShortcut() {
    const HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(initialized)) return initialized;

    wchar_t programs[MAX_PATH]{};
    HRESULT result = SHGetFolderPathW(nullptr, CSIDL_PROGRAMS, nullptr, SHGFP_TYPE_CURRENT, programs);
    IShellLinkW* link = nullptr;
    IPropertyStore* properties = nullptr;
    IPersistFile* file = nullptr;
    const auto shortcut = std::filesystem::path(programs) / L"ClipBridge.lnk";
    const auto executable = modulePath();
    if (SUCCEEDED(result)) result = CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(&link));
    if (SUCCEEDED(result)) result = link->SetPath(executable.c_str());
    if (SUCCEEDED(result)) result = link->SetDescription(L"ClipBridge clipboard uploads");
    if (SUCCEEDED(result)) result = link->QueryInterface(IID_PPV_ARGS(&properties));
    const PROPERTYKEY appIdKey{{0x9f4c2855, 0x9f79, 0x4b39,
        {0xa8, 0xd0, 0xe1, 0xd4, 0x2d, 0xe1, 0xd5, 0xf3}}, 5};
    PROPVARIANT property{};
    property.vt = VT_LPWSTR;
    property.pwszVal = const_cast<wchar_t*>(appId);
    if (SUCCEEDED(result)) result = properties->SetValue(appIdKey, property);
    if (SUCCEEDED(result)) result = properties->Commit();
    if (SUCCEEDED(result)) result = link->QueryInterface(IID_PPV_ARGS(&file));
    if (SUCCEEDED(result)) result = file->Save(shortcut.c_str(), TRUE);
    if (file) file->Release();
    if (properties) properties->Release();
    if (link) link->Release();
    CoUninitialize();
    return result;
}

void notify(const wchar_t* message) {
    const auto executable = powershellPath();
    const auto script = std::filesystem::path(modulePath()).parent_path() / L"clipbridge-notify.ps1";
    std::wstring command = L"\"" + executable + L"\" -NoProfile -NonInteractive -File \"" +
        script.wstring() + L"\" -Message \"" + message + L"\"";
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION child{};
    if (CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, FALSE,
            CREATE_NO_WINDOW, nullptr, nullptr, &startup, &child)) {
        CloseHandle(child.hThread);
        CloseHandle(child.hProcess);
    } else {
        MessageBoxW(window, message, title, MB_OK | MB_ICONINFORMATION);
    }
}

std::wstring processName(DWORD pid) {
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) return L"";
    wchar_t filename[32768];
    DWORD size = ARRAYSIZE(filename);
    const BOOL ok = QueryFullProcessImageNameW(process, 0, filename, &size);
    CloseHandle(process);
    return ok ? std::filesystem::path(std::wstring(filename, size)).filename().wstring() : L"";
}

bool publishProgress(HWND target, std::uint64_t requestId, const std::string& line) {
    TransferEvent event;
    event.requestId = requestId;
    if (line == "STATUS reading-clipboard") {
        event.phase = TransferPhase::ReadingClipboard;
        event.safeMessage = L"正在读取剪贴板";
    } else if (line == "STATUS encoding") {
        event.phase = TransferPhase::Encoding;
        event.safeMessage = L"正在编码图片";
    } else if (line == "STATUS packing") {
        event.phase = TransferPhase::Packing;
        event.safeMessage = L"正在准备文件";
    } else if (line == "STATUS connecting" || line == "STATUS reconnecting") {
        event.phase = TransferPhase::Connecting;
        event.safeMessage = L"正在连接 Debian";
    } else if (line == "STATUS verifying") {
        event.phase = TransferPhase::ServerVerifying;
        event.safeMessage = L"Debian 正在校验";
    } else if (line.rfind("NAME ", 0) == 0) {
        event.displayName = utf8ToWide(decodeBase64(line.substr(5)));
        if (event.displayName.size() > 120) event.displayName.resize(120);
        for (auto& character : event.displayName) {
            if (character < 0x20 || character == 0x7f || character == L'/' || character == L'\\' ||
                (character >= 0x202a && character <= 0x202e) ||
                (character >= 0x2066 && character <= 0x2069)) character = L' ';
        }
        event.phase = TransferPhase::Preparing;
    } else if (line.rfind("PROGRESS ", 0) == 0) {
        char extra;
        if (std::sscanf(line.c_str(), "PROGRESS %llu %llu%c", &event.completedBytes,
                &event.totalBytes, &extra) != 2 || !event.totalBytes ||
            event.completedBytes > event.totalBytes || event.totalBytes > 256ull * 1024 * 1024)
            return false;
        event.phase = TransferPhase::Uploading;
        event.totalKnown = true;
        event.safeMessage = L"正在上传";
    } else {
        return false;
    }
    auto notice = std::make_unique<TransferEvent>(std::move(event));
    if (PostMessageW(target, uploadProgress, 0, reinterpret_cast<LPARAM>(notice.get())))
        notice.release();
    return true;
}

void closeAgent() {
    if (agentInput) { CloseHandle(agentInput); agentInput = nullptr; }
    if (agentOutput) { CloseHandle(agentOutput); agentOutput = nullptr; }
    if (agentJob) { CloseHandle(agentJob); agentJob = nullptr; }
    if (agentProcess) { CloseHandle(agentProcess); agentProcess = nullptr; }
    agentBuffer.clear();
}

bool readAgentLine(std::string& line, ULONGLONG deadline, const std::atomic_bool& cancel) {
    while (GetTickCount64() < deadline && !cancel.load()) {
        const auto newline = agentBuffer.find('\n');
        if (newline != std::string::npos) {
            line = agentBuffer.substr(0, newline);
            agentBuffer.erase(0, newline + 1);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            return true;
        }
        if (!agentProcess || WaitForSingleObject(agentProcess, 0) == WAIT_OBJECT_0)
            return false;
        DWORD available = 0;
        if (!PeekNamedPipe(agentOutput, nullptr, 0, nullptr, &available, nullptr)) return false;
        if (available) {
            char data[4096];
            DWORD count = 0;
            if (!ReadFile(agentOutput, data, available < sizeof(data) ? available : sizeof(data), &count, nullptr))
                return false;
            agentBuffer.append(data, count);
            if (agentBuffer.size() > 2 * 1024 * 1024) return false;
        } else {
            Sleep(20);
        }
    }
    return false;
}

bool startAgent(HWND target, const std::atomic_bool& cancel, std::wstring& error) {
    closeAgent();
    const auto module = modulePath();
    const auto script = std::filesystem::path(module).parent_path() / L"clipbridge-agent.ps1";
    const auto executable = powershellPath();
    if (module.empty() || executable.empty() || !std::filesystem::is_regular_file(script)) {
        error = L"ClipBridge agent script is missing.";
        return false;
    }
    SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
    HANDLE childInput{}, parentInput{}, parentOutput{}, childOutput{};
    if (!CreatePipe(&childInput, &parentInput, &security, 0) ||
        !CreatePipe(&parentOutput, &childOutput, &security, 0) ||
        !SetHandleInformation(parentInput, HANDLE_FLAG_INHERIT, 0) ||
        !SetHandleInformation(parentOutput, HANDLE_FLAG_INHERIT, 0)) {
        if (childInput) CloseHandle(childInput);
        if (parentInput) CloseHandle(parentInput);
        if (parentOutput) CloseHandle(parentOutput);
        if (childOutput) CloseHandle(childOutput);
        error = L"Could not create the persistent channel pipes.";
        return false;
    }
    HANDLE nullDevice = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_EXISTING, 0, nullptr);
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    startup.hStdInput = childInput;
    startup.hStdOutput = childOutput;
    startup.hStdError = nullDevice;
    std::wstring command = L"\"" + executable + L"\" -NoProfile -NonInteractive -STA -File \"" +
        script.wstring() + L"\" -SshHost debian";
    PROCESS_INFORMATION child{};
    HANDLE job = CreateJobObjectW(nullptr, nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    const BOOL jobReady = job && SetInformationJobObject(job, JobObjectExtendedLimitInformation,
        &limits, sizeof(limits));
    const BOOL launched = jobReady && nullDevice != INVALID_HANDLE_VALUE && !cancel.load() &&
        CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, TRUE,
            CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, nullptr, &startup, &child);
    CloseHandle(childInput);
    CloseHandle(childOutput);
    if (nullDevice != INVALID_HANDLE_VALUE) CloseHandle(nullDevice);
    if (!launched) {
        if (parentInput) CloseHandle(parentInput);
        if (parentOutput) CloseHandle(parentOutput);
        if (job) CloseHandle(job);
        error = L"Could not start the persistent ClipBridge agent.";
        return false;
    }
    if (!AssignProcessToJobObject(job, child.hProcess) || ResumeThread(child.hThread) == static_cast<DWORD>(-1)) {
        TerminateProcess(child.hProcess, 1);
        CloseHandle(child.hThread);
        CloseHandle(child.hProcess);
        CloseHandle(parentInput);
        CloseHandle(parentOutput);
        CloseHandle(job);
        error = L"Could not attach the ClipBridge agent to its lifetime job.";
        return false;
    }
    CloseHandle(child.hThread);
    agentProcess = child.hProcess;
    agentJob = job;
    agentInput = parentInput;
    agentOutput = parentOutput;
    std::string line;
    if (!readAgentLine(line, GetTickCount64() + 30000, cancel)) {
        error = L"ClipBridge could not establish its dedicated SSH channel.";
        closeAgent();
        return false;
    }
    if (line.rfind("FATAL ", 0) == 0) {
        error = L"ClipBridge could not connect to Debian.";
        closeAgent();
        return false;
    }
    if (line != "READY") {
        error = L"ClipBridge returned an invalid channel status.";
        closeAgent();
        return false;
    }
    (void)target;
    return true;
}

std::string decodeBase64(const std::string& text) {
    static constexpr char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string result;
    unsigned int accumulator = 0;
    int bits = 0;
    for (const unsigned char character : text) {
        if (character == '=') break;
        const char* found = std::strchr(alphabet, character);
        if (!found) return {};
        accumulator = (accumulator << 6) | static_cast<unsigned int>(found - alphabet);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            result.push_back(static_cast<char>((accumulator >> bits) & 0xff));
        }
    }
    return result;
}

std::string sendUpload(HWND target, std::uint64_t requestId, const std::atomic_bool& cancel, std::wstring& error) {
    std::lock_guard<std::mutex> lock(agentMutex);
    if (cancel.load()) { error = L"Upload cancelled."; return {}; }
    if (!agentProcess && !startAgent(target, cancel, error)) return {};
    const char command[] = "UPLOAD\n";
    DWORD written = 0;
    if (!WriteFile(agentInput, command, static_cast<DWORD>(sizeof(command) - 1), &written, nullptr) ||
        written != sizeof(command) - 1) {
        error = L"The persistent SSH channel disconnected. Press Alt+Shift+V to retry.";
        closeAgent();
        return {};
    }
    std::string result;
    const auto deadline = GetTickCount64() + 30ull * 60 * 1000;
    while (!cancel.load()) {
        std::string line;
        if (!readAgentLine(line, deadline, cancel)) break;
        if (publishProgress(target, requestId, line)) continue;
        if (line.rfind("PATH ", 0) == 0) {
            result = decodeBase64(line.substr(5));
            break;
        }
        if (line.rfind("ERROR ", 0) == 0) {
            error = utf8ToWide(decodeBase64(line.substr(6)));
            if (error.empty()) error = L"Upload failed. Check the ClipBridge status.";
            break;
        }
        if (line.rfind("FATAL ", 0) == 0) {
            error = L"The persistent ClipBridge agent stopped unexpectedly.";
            closeAgent();
            break;
        }
        error = L"ClipBridge returned an invalid upload response.";
        closeAgent();
        break;
    }
    if (cancel.load()) {
        error = L"Upload cancelled. Server commit status may be unknown.";
        closeAgent();
        return {};
    }
    if (result.empty() && error.empty()) {
        error = L"Upload timed out or the SSH channel disconnected. No path was entered.";
        closeAgent();
        return {};
    }
    if (result.find_first_of("\r\n\t") != std::string::npos ||
        result.find("/../") != std::string::npos ||
        (result.size() >= 3 && result.compare(result.size() - 3, 3, "/..") == 0) ||
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, result.data(),
            static_cast<int>(result.size()), nullptr, 0) <= 0) {
        error = L"Debian returned an invalid path; nothing was entered.";
        return {};
    }
    for (const unsigned char character : result) {
        if (character < 0x20 || character == 0x7f) {
            error = L"Debian returned an invalid path; nothing was entered.";
            return {};
        }
    }
    return result;
}

std::wstring utf8ToWide(const std::string& text) {
    const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        text.data(), static_cast<int>(text.size()), nullptr, 0);
    if (length <= 0) return {};
    std::wstring result(static_cast<std::size_t>(length), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
            static_cast<int>(text.size()), result.data(), length) != length)
        return {};
    return result;
}

bool setClipboard(const std::string& path, DWORD sequence) {
    const UINT historyFormat = RegisterClipboardFormatW(L"CanIncludeInClipboardHistory");
    if (!historyFormat || !OpenClipboard(window)) return false;
    if (GetClipboardSequenceNumber() != sequence) {
        CloseClipboard();
        return false;
    }
    const auto text = utf8ToWide(path);
    if (text.empty()) { CloseClipboard(); return false; }
    const auto bytes = (text.size() + 1) * sizeof(wchar_t);
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    bool success = false;
    // A zero DWORD tells Windows to exclude this clipboard item from Win+V.
    HGLOBAL historyFlag = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(DWORD));
    if (memory && historyFlag) {
        if (void* dest = GlobalLock(memory)) {
            std::memcpy(dest, text.c_str(), bytes);
            GlobalUnlock(memory);
            if (EmptyClipboard() && SetClipboardData(historyFormat, historyFlag)) {
                historyFlag = nullptr; // Windows owns the handle after success.
                success = SetClipboardData(CF_UNICODETEXT, memory) != nullptr;
            }
        }
    }
    if (!success && memory) GlobalFree(memory);
    if (historyFlag) GlobalFree(historyFlag);
    CloseClipboard();
    return success;
}

bool paste(const Upload& upload) {
    if (terminal.empty() || !eventHook || upload.focusGeneration != focusGeneration ||
        upload.target != GetForegroundWindow() || GetTickCount64() - upload.started >= pasteTimeoutMs)
        return false;
    DWORD pid = 0;
    GetWindowThreadProcessId(upload.target, &pid);
    if (pid != upload.pid || _wcsicmp(processName(pid).c_str(), terminal.c_str())) return false;
    for (const int key : {VK_MENU, VK_CONTROL, VK_SHIFT, VK_LWIN, VK_RWIN, static_cast<int>('V')}) {
        if (GetAsyncKeyState(key) & 0x8000) return false;
    }
    INPUT input[6]{};
    const WORD keys[]{VK_CONTROL, VK_SHIFT, 'V', 'V', VK_SHIFT, VK_CONTROL};
    for (unsigned i = 0; i < ARRAYSIZE(input); ++i) {
        input[i].type = INPUT_KEYBOARD;
        input[i].ki.wVk = keys[i];
        if (i >= 3) input[i].ki.dwFlags = KEYEVENTF_KEYUP;
    }
    if (upload.target != GetForegroundWindow()) return false;
    if (!setClipboard(upload.path, upload.clipboardSequence)) return false;
    if (upload.target != GetForegroundWindow()) return false;
    return SendInput(ARRAYSIZE(input), input, sizeof(INPUT)) == ARRAYSIZE(input);
}

void CALLBACK foregroundChanged(HWINEVENTHOOK, DWORD, HWND, LONG, LONG, DWORD, DWORD) {
    ++focusGeneration;
}

LRESULT CALLBACK dispatch(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_HOTKEY && wParam == hotkeyId && !closing) {
        if (active) { notify(L"Upload already in progress."); return 0; }
        auto upload = std::make_unique<Upload>();
        upload->target = GetForegroundWindow();
        GetWindowThreadProcessId(upload->target, &upload->pid);
        upload->focusGeneration = focusGeneration;
        upload->started = GetTickCount64();
        upload->clipboardSequence = GetClipboardSequenceNumber();
        upload->requestId = nextRequestId.fetch_add(1);
        activeRequestId = upload->requestId;
        upload->pasteCandidate = !terminal.empty() &&
            !_wcsicmp(processName(upload->pid).c_str(), terminal.c_str());
        statusMonitor = MonitorFromWindow(upload->target, MONITOR_DEFAULTTOPRIMARY);
        currentDpi = GetDpiForWindow(upload->target);
        deadlineExpired = false;
        statusWasShown = false;
        progressDelayPending = false;
        phaseLabel = L"读取剪贴板";
        displayName.clear();
        byteLabel.clear();
        completedBytes = 0;
        totalBytes = 0;
        totalKnown = false;
        KillTimer(hwnd, statusExpiry);
        KillTimer(hwnd, progressDelay);
        SetTimer(hwnd, progressDelay, 300, nullptr);
        progressDelayPending = true;
        if (upload->pasteCandidate) SetTimer(hwnd, pasteDeadline, static_cast<UINT>(pasteTimeoutMs), nullptr);
        active = std::make_shared<std::atomic_bool>(false);
        upload->cancel = active;
        try {
            std::thread([task = std::move(upload), hwnd]() mutable {
                try { task->path = sendUpload(hwnd, task->requestId, *task->cancel, task->error); }
                catch (...) { task->error = L"Upload failed unexpectedly. No path was entered."; }
                Upload* result = task.release();
                if (!PostMessageW(hwnd, finished, 0, reinterpret_cast<LPARAM>(result))) delete result;
            }).detach();
        } catch (...) {
            active.reset();
            KillTimer(hwnd, pasteDeadline);
            showResult(L"Could not start the upload.");
        }
        return 0;
    }
    if (message == uploadProgress) {
        std::unique_ptr<TransferEvent> event(reinterpret_cast<TransferEvent*>(lParam));
        if (event && active && !closing && event->requestId == activeRequestId) {
            if (!event->displayName.empty()) displayName = event->displayName;
            if (!event->safeMessage.empty()) phaseLabel = event->safeMessage;
            if (event->totalKnown) {
                completedBytes = event->completedBytes;
                totalBytes = event->totalBytes;
                totalKnown = true;
                wchar_t label[96]{};
                const auto unit = totalBytes >= 1024ull * 1024 ? 1024.0 * 1024 : 1024.0;
                const auto suffix = totalBytes >= 1024ull * 1024 ? L"MiB" :
                    totalBytes >= 1024 ? L"KiB" : L"B";
                std::swprintf(label, ARRAYSIZE(label), L"已发送 %.1f / %.1f %ls  (%llu%%)",
                    completedBytes / unit, totalBytes / unit, suffix,
                    completedBytes * 100 / totalBytes);
                byteLabel = label;
            } else if (event->phase == TransferPhase::ServerVerifying) {
                totalKnown = false;
                byteLabel.clear();
            }
            refreshProgress();
        }
        return 0;
    }
    if (message == connectionFailed) {
        std::unique_ptr<std::wstring> error(reinterpret_cast<std::wstring*>(lParam));
        if (!closing && error) showResult(*error);
        return 0;
    }
    if (message == WM_TIMER && wParam == pasteDeadline) {
        KillTimer(hwnd, pasteDeadline);
        if (active && !closing) {
            deadlineExpired = true;
            refreshProgress();
        }
        return 0;
    }
    if (message == WM_TIMER && wParam == progressDelay) {
        KillTimer(hwnd, progressDelay);
        progressDelayPending = false;
        if (active && !closing) {
            showStatus(L"ClipBridge\r\n" + phaseLabel);
            statusWasShown = true;
        }
        return 0;
    }
    if (message == WM_TIMER && wParam == statusExpiry) {
        KillTimer(hwnd, statusExpiry);
        hideStatus();
        statusWasShown = false;
        return 0;
    }
    if (message == finished) {
        std::unique_ptr<Upload> upload(reinterpret_cast<Upload*>(lParam));
        active.reset();
        KillTimer(hwnd, pasteDeadline);
        KillTimer(hwnd, progressDelay);
        progressDelayPending = false;
        if (closing) {
            { std::lock_guard<std::mutex> lock(agentMutex); closeAgent(); }
            DestroyWindow(hwnd);
            return 0;
        }
        if (upload->cancel->load())
            showResult(L"Upload cancelled. Server commit status may be unknown.");
        else if (!upload->error.empty())
            showResult(upload->error);
        else if (upload->path.empty())
            showResult(L"Upload failed. No path was entered.");
        else if (paste(*upload)) {
            if (statusWasShown)
                showResult(L"已发送路径粘贴", 1000);
            else
                hideStatus();
        }
        else if (upload->pasteCandidate && GetTickCount64() - upload->started >= pasteTimeoutMs)
            showResult(L"Upload complete. Auto-input expired. Run clipbridge latest to retrieve the path.");
        else
            showResult(L"Upload complete. Path not entered. Run clipbridge latest to retrieve it.");
        return 0;
    }
    if (message == cancelUpload) {
        if (active) active->store(true);
        return 0;
    }
    if (message == WM_CLOSE) {
        closing = true;
        if (startupConnect) startupConnect->store(true);
        if (active) active->store(true);
        else {
            { std::lock_guard<std::mutex> lock(agentMutex); closeAgent(); }
            DestroyWindow(hwnd);
        }
        return 0;
    }
    if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argc == 2 && std::wstring(argv[1]) == L"--self-check") {
        ID2D1Factory* testD2d = nullptr;
        IDWriteFactory* testWrite = nullptr;
        const auto d2dResult = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &testD2d);
        const auto writeResult = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
            reinterpret_cast<IUnknown**>(&testWrite));
        if (testD2d) testD2d->Release();
        if (testWrite) testWrite->Release();
        LocalFree(argv);
        return SUCCEEDED(d2dResult) && SUCCEEDED(writeResult) ? 0 : 2;
    }
    if (argc == 2) {
        const std::wstring action = argv[1];
        if (action == L"--stop" || action == L"--cancel-upload") {
            LocalFree(argv);
            const HWND existing = FindWindowW(windowClass, title);
            if (!existing) return 0;
            return PostMessageW(existing, action == L"--stop" ? WM_CLOSE : cancelUpload, 0, 0)
                ? 0 : 1;
        }
    }
    bool valid = argv && (argc == 1 || argc == 3 || argc == 5);
    if (valid && argc >= 3) {
        terminal = argv[2];
        valid = std::wstring(argv[1]) == L"--auto-paste" && !terminal.empty() &&
            terminal.find_first_of(L"\\/") == std::wstring::npos;
    }
    if (valid && argc == 5) {
        const std::wstring seconds = argv[4];
        valid = std::wstring(argv[3]) == L"--paste-timeout" && !seconds.empty() &&
            seconds.size() <= 2 && seconds.find_first_not_of(L"0123456789") == std::wstring::npos;
        if (valid) {
            const auto value = std::wcstoul(seconds.c_str(), nullptr, 10);
            valid = value >= 1 && value <= 60;
            if (valid) pasteTimeoutMs = value * 1000;
        }
    }
    if (argv) LocalFree(argv);
    if (!valid) {
        MessageBoxW(nullptr, L"Usage: ClipBridgeHotkey.exe [--auto-paste terminal.exe [--paste-timeout seconds]] or --stop / --cancel-upload",
            title, MB_OK | MB_ICONERROR);
        return 1;
    }
    WNDCLASSW cls{};
    cls.lpfnWndProc = dispatch;
    cls.hInstance = instance;
    cls.lpszClassName = windowClass;
    if (!RegisterClassW(&cls)) return 1;
    window = CreateWindowW(cls.lpszClassName, title, WS_OVERLAPPED, 0, 0, 0, 0,
        nullptr, nullptr, instance, nullptr);
    if (!window) return 1;
    if (!initializeProgressWindow(instance))
        notify(L"Native progress card is unavailable; uploads can continue without it.");
    if (FAILED(registerNotificationShortcut())) {
        MessageBoxW(window, L"Could not register Windows notifications for ClipBridge.", title, MB_OK | MB_ICONERROR);
        DestroyWindow(window);
        return 1;
    }
    if (!RegisterHotKey(window, hotkeyId, MOD_ALT | MOD_SHIFT | MOD_NOREPEAT, 'V')) {
        const auto error = L"Could not register Alt+Shift+V. Win32 error: " + std::to_wstring(GetLastError());
        notify(error.c_str());
        DestroyWindow(window);
        return 1;
    }
    eventHook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr,
        foregroundChanged, 0, 0, WINEVENT_OUTOFCONTEXT);
    startupConnect = std::make_shared<std::atomic_bool>(false);
    try {
        std::thread([hwnd = window, token = startupConnect]() {
            std::wstring error;
            bool connected = false;
            {
                std::lock_guard<std::mutex> lock(agentMutex);
                if (!token->load() && !closing) connected = startAgent(hwnd, *token, error);
            }
            (void)error;
            (void)connected;
            (void)hwnd;
        }).detach();
    } catch (...) {
        notify(L"ClipBridge could not start its background SSH connection. The first hotkey will retry.");
    }
    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    if (eventHook) UnhookWinEvent(eventHook);
    releaseRenderTarget();
    if (titleFormat) titleFormat->Release();
    if (bodyFormat) bodyFormat->Release();
    if (smallFormat) smallFormat->Release();
    if (writeFactory) writeFactory->Release();
    if (d2dFactory) d2dFactory->Release();
    return 0;
}

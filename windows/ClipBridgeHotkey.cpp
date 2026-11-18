#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <atomic>
#include <cstring>
#include <cwchar>
#include <filesystem>
#include <memory>
#include <string>
#include <thread>

constexpr UINT finished = WM_APP + 1;
constexpr UINT trayEvent = WM_APP + 2;
constexpr UINT hotkeyId = 1;
constexpr wchar_t title[] = L"ClipBridge";

struct Upload {
    HWND target{};
    DWORD pid{};
    DWORD clipboardSequence{};
    unsigned long long focusGeneration{};
    ULONGLONG started{};
    std::string path;
    std::shared_ptr<std::atomic_bool> cancel;
};

HWND window;
HWINEVENTHOOK eventHook;
unsigned long long focusGeneration;
std::shared_ptr<std::atomic_bool> active;
bool closing;
std::wstring terminal;
ULONGLONG pasteTimeoutMs = 8000;
NOTIFYICONDATAW icon{};

void notify(const wchar_t* message, DWORD kind = NIIF_INFO) {
    icon.uFlags = NIF_INFO;
    icon.dwInfoFlags = kind;
    lstrcpynW(icon.szInfoTitle, title, ARRAYSIZE(icon.szInfoTitle));
    lstrcpynW(icon.szInfo, message, ARRAYSIZE(icon.szInfo));
    if (!Shell_NotifyIconW(NIM_MODIFY, &icon)) {
        MessageBoxW(window, message, title, MB_OK | MB_ICONINFORMATION);
    }
}

std::wstring modulePath() {
    wchar_t exe[32768];
    const DWORD n = GetModuleFileNameW(nullptr, exe, ARRAYSIZE(exe));
    return n && n < ARRAYSIZE(exe) ? std::wstring(exe, n) : L"";
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

std::string sendUpload(const std::atomic_bool& cancel) {
    const auto module = modulePath();
    if (module.empty()) return {};
    const auto script = std::filesystem::path(module).parent_path() / L"clipbridge-send.ps1";
    wchar_t system[32768];
    const UINT length = GetSystemDirectoryW(system, ARRAYSIZE(system));
    if (!length || length >= ARRAYSIZE(system)) return {};
    const std::wstring executable = std::wstring(system, length) +
        L"\\WindowsPowerShell\\v1.0\\powershell.exe";
    std::wstring command = L"\"" + executable + L"\" -NoProfile -NonInteractive -STA -File \"" +
        script.wstring() + L"\"";
    SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
    HANDLE reader{}, writer{};
    if (!CreatePipe(&reader, &writer, &security, 0)) return {};
    if (!SetHandleInformation(reader, HANDLE_FLAG_INHERIT, 0)) {
        CloseHandle(reader);
        CloseHandle(writer);
        return {};
    }
    HANDLE nullDevice = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_EXISTING, 0, nullptr);
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    startup.hStdInput = nullDevice;
    startup.hStdError = nullDevice;
    startup.hStdOutput = writer;
    PROCESS_INFORMATION child{};
    HANDLE job = CreateJobObjectW(nullptr, nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    const BOOL ready = job && SetInformationJobObject(job, JobObjectExtendedLimitInformation,
        &limits, sizeof(limits));
    const BOOL launched = ready && !cancel.load() && nullDevice != INVALID_HANDLE_VALUE &&
        CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, TRUE,
            CREATE_NEW_CONSOLE | CREATE_SUSPENDED, nullptr, nullptr, &startup, &child);
    CloseHandle(writer);
    if (nullDevice != INVALID_HANDLE_VALUE) CloseHandle(nullDevice);
    std::string output;
    if (launched) {
        const bool started = AssignProcessToJobObject(job, child.hProcess) &&
            ResumeThread(child.hThread) != static_cast<DWORD>(-1);
        if (!started) TerminateProcess(child.hProcess, 1);
        CloseHandle(child.hThread);
        const auto deadline = GetTickCount64() + 140000;
        bool valid = started;
        while (valid) {
            if (cancel.load()) { valid = false; break; }
            DWORD available = 0;
            if (!PeekNamedPipe(reader, nullptr, 0, nullptr, &available, nullptr)) break;
            if (available) {
                char data[4096];
                DWORD count = 0;
                if (!ReadFile(reader, data, available < sizeof(data) ? available : sizeof(data), &count, nullptr)) break;
                output.append(data, count);
                if (output.size() > 512000) { valid = false; break; }
            } else if (WaitForSingleObject(child.hProcess, 20) == WAIT_OBJECT_0) {
                break;
            }
            if (GetTickCount64() >= deadline) { valid = false; break; }
        }
        if (WaitForSingleObject(child.hProcess, 200) != WAIT_OBJECT_0) {
            TerminateProcess(child.hProcess, 1);
            valid = false;
        }
        DWORD exitCode = 1;
        GetExitCodeProcess(child.hProcess, &exitCode);
        CloseHandle(child.hProcess);
        if (!valid || exitCode) output.clear();
    }
    if (job) CloseHandle(job);
    CloseHandle(reader);
    while (!output.empty() && (output.back() == '\r' || output.back() == '\n')) output.pop_back();
    if (output.empty() || output.front() != '/' ||
        output.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./- ") != std::string::npos)
        return {};
    return output;
}

bool setClipboard(const std::string& path, DWORD sequence) {
    if (!OpenClipboard(window)) return false;
    if (GetClipboardSequenceNumber() != sequence) {
        CloseClipboard();
        return false;
    }
    const std::wstring text(path.begin(), path.end());
    const auto bytes = (text.size() + 1) * sizeof(wchar_t);
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    bool success = false;
    if (memory) {
        if (void* dest = GlobalLock(memory)) {
            std::memcpy(dest, text.c_str(), bytes);
            GlobalUnlock(memory);
            success = EmptyClipboard() && SetClipboardData(CF_UNICODETEXT, memory);
        }
        if (!success) GlobalFree(memory);
    }
    CloseClipboard();
    return success;
}

bool paste(const Upload& upload) {
    if (terminal.empty() || !eventHook || upload.focusGeneration != focusGeneration ||
        upload.target != GetForegroundWindow() || GetTickCount64() - upload.started > pasteTimeoutMs)
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
        upload->clipboardSequence = GetClipboardSequenceNumber();
        upload->focusGeneration = focusGeneration;
        upload->started = GetTickCount64();
        active = std::make_shared<std::atomic_bool>(false);
        upload->cancel = active;
        icon.uFlags = NIF_TIP;
        lstrcpynW(icon.szTip, L"ClipBridge - uploading", ARRAYSIZE(icon.szTip));
        Shell_NotifyIconW(NIM_MODIFY, &icon);
        try {
            std::thread([task = std::move(upload), hwnd]() mutable {
                try { task->path = sendUpload(*task->cancel); } catch (...) {}
                Upload* result = task.release();
                if (!PostMessageW(hwnd, finished, 0, reinterpret_cast<LPARAM>(result))) delete result;
            }).detach();
        } catch (...) {
            active.reset();
            notify(L"Could not start the upload.", NIIF_ERROR);
        }
        return 0;
    }
    if (message == finished) {
        std::unique_ptr<Upload> upload(reinterpret_cast<Upload*>(lParam));
        active.reset();
        if (closing) { DestroyWindow(hwnd); return 0; }
        icon.uFlags = NIF_TIP;
        lstrcpynW(icon.szTip, L"ClipBridge - Alt+Shift+V", ARRAYSIZE(icon.szTip));
        Shell_NotifyIconW(NIM_MODIFY, &icon);
        if (upload->cancel->load())
            notify(L"Upload cancelled. Server commit status may be unknown.");
        else if (upload->path.empty())
            notify(L"Upload failed or the receipt was unavailable. Run clipbridge-send.ps1 for details.", NIIF_ERROR);
        else if (!setClipboard(upload->path, upload->clipboardSequence))
            notify(L"Upload succeeded. The clipboard changed or was unavailable. Query clipbridge latest.");
        else if (!paste(*upload))
            notify(L"Upload succeeded. Path copied for manual paste.");
        return 0;
    }
    if (message == trayEvent && lParam == WM_RBUTTONUP) {
        POINT point{};
        GetCursorPos(&point);
        HMENU menu = CreatePopupMenu();
        AppendMenuW(menu, MF_STRING, 1, L"Exit ClipBridge");
        if (active) AppendMenuW(menu, MF_STRING, 2, L"Cancel upload");
        SetForegroundWindow(hwnd);
        const auto choice = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
            point.x, point.y, 0, hwnd, nullptr);
        DestroyMenu(menu);
        if (choice == 1) SendMessageW(hwnd, WM_CLOSE, 0, 0);
        if (choice == 2 && active) active->store(true);
        return 0;
    }
    if (message == WM_CLOSE) {
        closing = true;
        if (active) active->store(true);
        else DestroyWindow(hwnd);
        return 0;
    }
    if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
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
        MessageBoxW(nullptr, L"Usage: ClipBridgeHotkey.exe [--auto-paste terminal.exe [--paste-timeout seconds]]",
            title, MB_OK | MB_ICONERROR);
        return 1;
    }
    WNDCLASSW cls{};
    cls.lpfnWndProc = dispatch;
    cls.hInstance = instance;
    cls.lpszClassName = L"ClipBridgeHotkeyWindow";
    if (!RegisterClassW(&cls)) return 1;
    window = CreateWindowW(cls.lpszClassName, title, WS_OVERLAPPED, 0, 0, 0, 0,
        nullptr, nullptr, instance, nullptr);
    if (!window) return 1;
    if (!RegisterHotKey(window, hotkeyId, MOD_ALT | MOD_SHIFT | MOD_NOREPEAT, 'V')) {
        const auto error = L"Could not register Alt+Shift+V. Win32 error: " + std::to_wstring(GetLastError());
        MessageBoxW(window, error.c_str(), title, MB_OK | MB_ICONERROR);
        DestroyWindow(window);
        return 1;
    }
    eventHook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr,
        foregroundChanged, 0, 0, WINEVENT_OUTOFCONTEXT);
    icon.cbSize = sizeof(icon);
    icon.hWnd = window;
    icon.uID = 1;
    icon.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
    icon.uCallbackMessage = trayEvent;
    icon.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    lstrcpynW(icon.szTip, L"ClipBridge - Alt+Shift+V", ARRAYSIZE(icon.szTip));
    Shell_NotifyIconW(NIM_ADD, &icon);
    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    Shell_NotifyIconW(NIM_DELETE, &icon);
    if (eventHook) UnhookWinEvent(eventHook);
    return 0;
}

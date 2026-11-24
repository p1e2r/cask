/*
 * Cask steamwebhelper wrapper (MIT).
 *
 * Steam's Chromium UI (steamwebhelper.exe) fails under free Wine on macOS unless its GPU work runs
 * in-process. Steam doesn't let us pass Chromium flags, so Cask renames the real helper to
 * steamwebhelper.real.exe and puts this wrapper in its place. It starts the real helper with the
 * original command line plus the flags in steamwebhelper.cask-args (default: --in-process-gpu),
 * and ties the child's lifetime to its own so Steam can still stop it.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

static const wchar_t *skip_argv0(const wchar_t *cmd) {
    if (*cmd == L'"') {
        cmd++;
        while (*cmd && *cmd != L'"') cmd++;
        if (*cmd) cmd++;
    } else {
        while (*cmd && *cmd != L' ' && *cmd != L'\t') cmd++;
    }
    while (*cmd == L' ' || *cmd == L'\t') cmd++;
    return cmd;
}

static void read_extra_args(const wchar_t *dir, wchar_t *out, size_t cap) {
    wchar_t path[MAX_PATH * 2];
    swprintf(path, MAX_PATH * 2, L"%ls\\steamwebhelper.cask-args", dir);
    wcscpy(out, L"--in-process-gpu");
    FILE *f = _wfopen(path, L"rb");
    if (!f) return;
    char buf[2048];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = 0;
    for (size_t i = 0; i < n; i++) if (buf[i] == '\r' || buf[i] == '\n') buf[i] = ' ';
    if (MultiByteToWideChar(CP_UTF8, 0, buf, -1, out, (int)cap) == 0) wcscpy(out, L"--in-process-gpu");
}

int wmain(void) {
    wchar_t self[MAX_PATH * 2];
    DWORD len = GetModuleFileNameW(NULL, self, MAX_PATH * 2);
    if (len == 0) return 1;
    wchar_t *slash = wcsrchr(self, L'\\');
    if (!slash) return 1;
    *slash = 0;
    const wchar_t *dir = self;

    wchar_t real[MAX_PATH * 2];
    swprintf(real, MAX_PATH * 2, L"%ls\\steamwebhelper.real.exe", dir);

    wchar_t extra[2048];
    read_extra_args(dir, extra, 2048);

    const wchar_t *rest = skip_argv0(GetCommandLineW());
    size_t size = wcslen(real) + wcslen(rest) + wcslen(extra) + 16;
    wchar_t *cmd = (wchar_t *)HeapAlloc(GetProcessHeap(), 0, size * sizeof(wchar_t));
    if (!cmd) return 1;
    /* Flags go after Chromium's own switches but before any "--" terminator is unlikely; append. */
    swprintf(cmd, size, L"\"%ls\" %ls %ls", real, rest, extra);

    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
        ZeroMemory(&info, sizeof(info));
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, sizeof(info));
    }

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    GetStartupInfoW(&si);
    if (!CreateProcessW(real, cmd, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, NULL, &si, &pi)) {
        return (int)GetLastError();
    }
    if (job) AssignProcessToJobObject(job, pi.hProcess);
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    return (int)code;
}

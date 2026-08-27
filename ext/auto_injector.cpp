// ============================================================
// CSGO Legs Auto Injector (32-bit)
// Usage: auto_injector.exe [DLL path] [process name=csgo.exe] [timeout sec=300]
// Behavior:
//   1. Wait for process (game) to appear   -> keep polling
//   2. Wait for client.dll module to load  -> keep polling
//   3. Inject DLL via CreateRemoteThread(LoadLibraryA)
//   4. If already injected, skip and report
// ============================================================

#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>

static DWORD FindProcess(const char* name)
{
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;

    PROCESSENTRY32 pe;
    pe.dwSize = sizeof(pe);
    DWORD pid = 0;
    if (Process32First(snap, &pe))
    {
        do
        {
            if (_stricmp(pe.szExeFile, name) == 0)
            {
                pid = pe.th32ProcessID;
                break;
            }
        } while (Process32Next(snap, &pe));
    }
    CloseHandle(snap);
    return pid;
}

// Check if a module name is loaded in a process (case-insensitive)
static bool HasModule(DWORD pid, const char* modName)
{
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, pid);
    if (snap == INVALID_HANDLE_VALUE) return false;

    MODULEENTRY32 me;
    me.dwSize = sizeof(me);
    bool found = false;
    if (Module32First(snap, &me))
    {
        do
        {
            if (_stricmp(me.szModule, modName) == 0)
            {
                found = true;
                break;
            }
        } while (Module32Next(snap, &me));
    }
    CloseHandle(snap);
    return found;
}

// Inject dllPath into pid via LoadLibraryA remote thread.
// Returns module handle (HMODULE) or 0 on failure.
static HMODULE InjectDll(DWORD pid, const char* dllPath)
{
    HANDLE hProc = OpenProcess(PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION |
                               PROCESS_VM_OPERATION | PROCESS_VM_WRITE | PROCESS_VM_READ,
                               FALSE, pid);
    if (!hProc)
    {
        printf("[Inject] OpenProcess failed (err %lu). Run as admin?\n", GetLastError());
        return 0;
    }

    size_t len = strlen(dllPath) + 1;
    void* remote = VirtualAllocEx(hProc, nullptr, len, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote)
    {
        printf("[Inject] VirtualAllocEx failed (err %lu)\n", GetLastError());
        CloseHandle(hProc);
        return 0;
    }

    if (!WriteProcessMemory(hProc, remote, dllPath, len, nullptr))
    {
        printf("[Inject] WriteProcessMemory failed (err %lu)\n", GetLastError());
        VirtualFreeEx(hProc, remote, 0, MEM_RELEASE);
        CloseHandle(hProc);
        return 0;
    }

    HMODULE hKernel = GetModuleHandleA("kernel32.dll");
    FARPROC pLoadLib = GetProcAddress(hKernel, "LoadLibraryA");
    HANDLE hThread = CreateRemoteThread(hProc, nullptr, 0,
                                        (LPTHREAD_START_ROUTINE)pLoadLib,
                                        remote, 0, nullptr);
    if (!hThread)
    {
        printf("[Inject] CreateRemoteThread failed (err %lu)\n", GetLastError());
        VirtualFreeEx(hProc, remote, 0, MEM_RELEASE);
        CloseHandle(hProc);
        return 0;
    }

    WaitForSingleObject(hThread, 10000);
    DWORD exitCode = 0;
    GetExitCodeThread(hThread, &exitCode);

    CloseHandle(hThread);
    VirtualFreeEx(hProc, remote, 0, MEM_RELEASE);
    CloseHandle(hProc);
    return (HMODULE)exitCode;
}

// Wait until process appears (or timeout). Returns pid or 0.
static DWORD WaitProcess(const char* procName, int timeoutSec, int* waitedSec)
{
    printf("[Auto] 等待游戏进程 \"%s\" (最长 %d 秒)...\n", procName, timeoutSec);
    DWORD pid = 0;
    int waited = 0;
    while (waited < timeoutSec)
    {
        pid = FindProcess(procName);
        if (pid)
            break;
        printf("[Auto] 游戏未启动，继续等待...(已 %d 秒)\r", waited);
        fflush(stdout);
        Sleep(500);
        waited += 1;
    }
    if (waitedSec) *waitedSec = waited;
    return pid;
}

// Wait until module loaded in pid (or timeout). Returns true if loaded.
static bool WaitModule(DWORD pid, const char* modName, int timeoutSec, int* waitedSec)
{
    printf("[Auto] 等待 %s 加载...\n", modName);
    int waited = 0;
    while (waited < timeoutSec)
    {
        if (HasModule(pid, modName))
        {
            if (waitedSec) *waitedSec = waited;
            return true;
        }
        printf("[Auto] %s 未加载，继续等待...(已 %d 秒)\r", modName, waited);
        fflush(stdout);
        Sleep(500);
        waited += 1;
    }
    return false;
}

// 常驻监视循环：每次游戏启动 → 自动注入；游戏退出 → 继续待命。
static int WatchLoop(const char* dllPath, const char* procName, int timeoutSec)
{
    printf("[Auto] ===== 常驻守护模式 (watch) =====\n");
    printf("[Auto] 之后每次启动 %s 都会自动注入 %s\n", procName, dllPath);
    printf("[Auto] 关闭本窗口 = 停止守护 (只影响自动注入, 不影响游戏)。\n");
    printf("[Auto] -------------------------------------------------------\n");

    for (;;)
    {
        DWORD pid = WaitProcess(procName, timeoutSec, NULL);
        if (!pid)
        {
            printf("\n[Auto] 等待超时，重新进入待命...\n");
            continue;
        }
        printf("\n[Auto] 检测到 %s (PID=%lu)\n", procName, pid);

        if (HasModule(pid, "csgo_legs_ext.dll"))
        {
            printf("[Auto] 本次会话已注入过，跳过。\n");
        }
        else
        {
            if (!WaitModule(pid, "client.dll", timeoutSec, NULL))
            {
                printf("\n[Auto] client.dll 超时未加载，跳过本次。\n");
            }
            else
            {
                printf("\n[Auto] client.dll 已加载，注入中...\n");
                HMODULE hMod = InjectDll(pid, dllPath);
                if (hMod)
                    printf("[Auto] 注入成功! 模块基址 0x%p (游戏内 sm_legs 可开启看腿)\n", (void*)hMod);
                else
                    printf("[Auto] 注入失败 (err %lu)\n", GetLastError());
            }
        }

        // 等游戏退出（进程消失），再进入下一轮待命
        printf("[Auto] 监视中... 等 %s 退出后重新待命\r", procName);
        while (FindProcess(procName))
            Sleep(1000);
        printf("\n[Auto] %s 已退出。重新待命。\n", procName);
    }
    return 0;
}

int main(int argc, char* argv[])
{
    const char* dllPath = (argc >= 2) ? argv[1] : "csgo_legs_ext.dll";
    const char* procName = (argc >= 3) ? argv[2] : "csgo.exe";
    int timeoutSec = (argc >= 4) ? atoi(argv[3]) : 300;
    bool watch = (argc >= 5) ? (atoi(argv[4]) != 0) : false;

    // Verify DLL exists
    DWORD attr = GetFileAttributesA(dllPath);
    if (attr == INVALID_FILE_ATTRIBUTES)
    {
        printf("[Auto] Error: DLL not found: %s\n", dllPath);
        return 1;
    }

    if (watch)
        return WatchLoop(dllPath, procName, timeoutSec);

    // ---- 一次性模式（原逻辑）----
    DWORD pid = WaitProcess(procName, timeoutSec, NULL);
    if (!pid)
    {
        printf("\n[Auto] 超时：未找到进程 %s\n", procName);
        return 1;
    }
    printf("\n[Auto] 找到进程 %s (PID=%lu)\n", procName, pid);

    if (HasModule(pid, "csgo_legs_ext.dll"))
    {
        printf("[Auto] 已注入过 csgo_legs_ext.dll，跳过重复注入。\n");
        return 0;
    }

    if (!WaitModule(pid, "client.dll", timeoutSec, NULL))
    {
        printf("\n[Auto] 超时：client.dll 未加载\n");
        return 1;
    }
    printf("\n[Auto] client.dll 已加载，开始注入...\n");

    HMODULE hMod = InjectDll(pid, dllPath);
    if (hMod)
    {
        printf("[Auto] 注入成功! 模块基址 0x%p\n", (void*)hMod);
        printf("[Auto] 游戏内: sm_legs 开启看腿, sm_legs_dbg 查看状态\n");
    }
    else
    {
        printf("[Auto] 注入失败 (LoadLibrary 返回 0, err %lu)\n", GetLastError());
        return 1;
    }

    return 0;
}

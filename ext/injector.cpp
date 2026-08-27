// ============================================================
// CSGO Legs Injector (32-bit)
// Usage: injector.exe [DLL path] [process name=csgo.exe]
// Injects csgo_legs_ext.dll into the csgo.exe process
// ============================================================

#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>

// Find PID by process name (32-bit enumeration)
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

int main(int argc, char* argv[])
{
    const char* dllPath = (argc >= 2) ? argv[1] : "csgo_legs_ext.dll";
    const char* procName = (argc >= 3) ? argv[2] : "csgo.exe";

    // Verify DLL exists
    DWORD attr = GetFileAttributesA(dllPath);
    if (attr == INVALID_FILE_ATTRIBUTES)
    {
        printf("[Inject] Error: DLL not found: %s\n", dllPath);
        return 1;
    }

    // Find target process
    DWORD pid = FindProcess(procName);
    if (!pid)
    {
        printf("[Inject] Process not found: %s (start the game first)\n", procName);
        return 1;
    }
    printf("[Inject] Found process %s (PID=%lu)\n", procName, pid);

    HANDLE hProc = OpenProcess(PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION |
                               PROCESS_VM_OPERATION | PROCESS_VM_WRITE | PROCESS_VM_READ,
                               FALSE, pid);
    if (!hProc)
    {
        printf("[Inject] OpenProcess failed (err %lu). Run as admin?\n", GetLastError());
        return 1;
    }

    // Allocate memory in target process for DLL path
    size_t len = strlen(dllPath) + 1;
    void* remote = VirtualAllocEx(hProc, nullptr, len, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote)
    {
        printf("[Inject] VirtualAllocEx failed (err %lu)\n", GetLastError());
        CloseHandle(hProc);
        return 1;
    }

    if (!WriteProcessMemory(hProc, remote, dllPath, len, nullptr))
    {
        printf("[Inject] WriteProcessMemory failed (err %lu)\n", GetLastError());
        VirtualFreeEx(hProc, remote, 0, MEM_RELEASE);
        CloseHandle(hProc);
        return 1;
    }

    // CreateRemoteThread + LoadLibraryW
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
        return 1;
    }

    // Wait for injection to complete
    WaitForSingleObject(hThread, 10000);
    DWORD exitCode = 0;
    GetExitCodeThread(hThread, &exitCode);

    if (exitCode != 0)
    {
        printf("[Inject] Success! DLL injected (module 0x%p)\n", (void*)exitCode);
        printf("[Inject] Plugin writes status to legs_ext_state.txt every ~1s\n");
    }
    else
    {
        printf("[Inject] LoadLibrary returned 0 - injection may have failed (err %lu)\n", GetLastError());
    }

    CloseHandle(hThread);
    VirtualFreeEx(hProc, remote, 0, MEM_RELEASE);
    CloseHandle(hProc);
    return 0;
}

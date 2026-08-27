// ============================================================
// CSGO Legs 注入 DLL —— 看腿骨骼矩阵隐藏（客户端侧）
// 功能：
//   1. 注入到 csgo.exe（32 位）后 GetModuleHandle("client.dll") 拿基址
//   2. Detour hook C_BaseAnimating::SetupBones（client.dll + RVA 0x1D3140）
//   3. 读 SourceMod 写的控制文件 legs_ext_ctrl.txt（腿实体）
//   4. post-hook 把腿实体 spine 根+后代 骨骼矩阵 3×3 归零并平移到 head 位置
//      → 上半身 mesh 塌成一点消失，腿（pelvis 后代）保留（Michael CS:S 方法）
//   5. 写状态文件 legs_ext_state.txt（hook 就绪/基址/改写次数）
// ★ v5.20 阴影移除已移交服务端插件（EF_NOSHADOWDEPTH|EF_NOCSM，借鉴 L4D 腿部脚本），
//   DLL 不再处理阴影。阴影相关逆向代码备份在 csgo_legs_ext_shadow_backup_v519.cpp。
// 偏移（2023 legacy client.dll 逆向确认）：
//   SetupBones          = 基址 + 0x1D3140
//   m_EntIndex          = this + 0x60
//   m_CachedBoneData    = this + 0x2910（矩阵数组指针，48B/骨骼）
//   骨骼数              = this + 0x291C
//   m_pStudioHdr        = this + 0x294C（CStudioHdr*）
//   矩阵平移            = +0x0C(x) +0x1C(y) +0x2C(z)
// 控制文件格式（SourceMod 写）：
//   第1行: 开关(1=开 0=关)
//   之后每行: 实体索引 （腿实体）
// 状态文件格式（DLL 写）：
//   ready=1/0  base=0x..  setupbones=0x..  writes=N  enabled=1/0
// ============================================================

#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string>
#include <vector>
#include <set>
#include <map>
#include <mutex>

// ---------- 逆向偏移 ----------
#define SETUPBONES_RVA       0x1D3140
#define SETUPBONES_MAGIC     0x83EC8B55     // 小端 55 8B EC 83
#define OFF_ENTINDEX         0x60
#define OFF_CACHEDBONE       0x2910
#define OFF_BONECOUNT        0x291C
#define OFF_STUDIOHDR        0x294C   // CStudioHdr*
// studiohdr_t 偏移（逆向/2018 源码确认）
#define HDR_NUMBONES         0x9C
#define HDR_BONEINDEX        0xA0
#define BONE_SIZE            0xD8     // mstudiobone_t
#define BONE_NAMIDX          0x00     // sznameindex（相对骨骼记录）
#define BONE_PARENT_IDX      0x04     // parent（父骨骼索引，层级遍历用）
#define BONE_TRANS_X         0x0C
#define BONE_TRANS_Y         0x1C
#define BONE_TRANS_Z         0x2C

// 通信文件
#define CTRL_FILE    "legs_ext_ctrl.txt"
#define STATE_FILE   "legs_ext_state.txt"

// ---------- SetupBones 签名 ----------
typedef bool(__thiscall *SetupBonesFn)(void* thisPtr, float* pBoneToWorldOut,
                                       int nMaxBones, int boneMask, float currentTime);

static SetupBonesFn g_original = nullptr;
static std::mutex g_mtx;
static std::map<int, std::vector<int>> g_boneMap;  // 实体索引 -> 目标标记
static volatile bool g_enabled = false;
static volatile long g_writes = 0;
static volatile bool g_ready = false;
static uintptr_t g_clientBase = 0;
static uintptr_t g_setupBones = 0;

// ---------- Detour ----------
static BYTE g_origBytes[16];     // 原函数前若干字节
static int  g_patchLen = 0;      // 覆盖长度（完整指令）
static void* g_trampoline = nullptr;

static void WriteJmp(BYTE* at, void* dest)
{
    at[0] = 0xE9;  // jmp rel32
    *(int*)(at + 1) = (int)((BYTE*)dest - (at + 5));
}

static void* AllocExec(size_t size)
{
    return VirtualAlloc(nullptr, size, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
}

// 计算前 N 字节覆盖的完整指令长度（x86，覆盖到指令边界，至少 5 字节）
static int CalcPatchLen(const BYTE* code)
{
    int i = 0;
    while (i < 5)
    {
        BYTE op = code[i];
        if (op == 0x55) { i += 1; continue; }                    // push ebp
        if (op == 0x8B) { i += 2; continue; }                    // mov r32,r32
        if (op == 0x83) { i += 3; continue; }                    // and/or/add r/m32, imm8
        if (op == 0xB8) { i += 5; continue; }                    // mov eax, imm32
        i += 1;  // 保守
    }
    return i;
}

// ---------- 骨骼层级解析（Michael CS:S 方法） ----------
// this+0x294C = CStudioHdr*, +0 = studiohdr_t*, +0x9C=numbones, +0xA0=boneindex
// 隐藏策略：
//   找 spine 根（深度最浅的 spine 骨骼）→ 收集它 + 所有后代（parent 链）
//   腿是 pelvis 的孩子，不在 spine 分支下 → 天然保留
//   塌缩目标 = head 骨骼位置，矩阵 3×3 归零 → mesh 塌成一点
struct BoneHideInfo
{
    std::vector<int> bones;   // 要隐藏的骨骼（spine 根 + 所有后代）
    int collapseTarget;       // 塌缩目标骨骼（head），-1 = 用根骨骼0
    int spineRoot;            // spine 根索引，-1 = 未找到（关键词兜底）
};

static std::mutex g_cacheMtx;
static std::map<int, BoneHideInfo> g_boneCache;
static char g_boneDiag[2048] = "";     // 最近一次解析诊断
static int  g_boneDiagEnt = 0;

static const BoneHideInfo& GetEntityBones(void* thisPtr, int ent)
{
    std::lock_guard<std::mutex> lock(g_cacheMtx);
    auto it = g_boneCache.find(ent);
    if (it != g_boneCache.end())
        return it->second;

    BoneHideInfo info;
    info.collapseTarget = -1;
    info.spineRoot = -1;

    int numBones = 0, boneIdx = 0;
    void** pCSH = (void**)((char*)thisPtr + OFF_STUDIOHDR);
    if (pCSH && *pCSH)
    {
        void** pPhdr = (void**)(*pCSH);
        if (pPhdr && *pPhdr)
        {
            BYTE* phdr = (BYTE*)*pPhdr;
            numBones = *(int*)(phdr + HDR_NUMBONES);
            boneIdx = *(int*)(phdr + HDR_BONEINDEX);
            if (numBones > 0 && numBones < 512 && boneIdx > 0 && boneIdx < 0x400000)
            {
                // 一次性解析所有骨骼名 + parent（原始索引直用）
                std::vector<const char*> names(numBones, nullptr);
                std::vector<int> parents(numBones, -1);
                for (int i = 0; i < numBones; i++)
                {
                    BYTE* bone = phdr + boneIdx + i * BONE_SIZE;
                    int nameIdx = *(int*)(bone + BONE_NAMIDX);
                    if (nameIdx < 0 || nameIdx > 0x100000) continue;
                    names[i] = (const char*)(bone + nameIdx);
                    parents[i] = *(int*)(bone + BONE_PARENT_IDX);
                }

                // 1) 找 spine 根：名字含 "spine"，选深度最浅（最靠近 pelvis）
                int bestSpine = -1, bestDepth = 9999;
                for (int i = 0; i < numBones; i++)
                {
                    if (!names[i] || !strstr(names[i], "spine")) continue;
                    int depth = 0, p = parents[i];
                    while (p >= 0 && depth < 64 && p < numBones && names[p])
                    { depth++; p = parents[p]; }
                    if (depth < bestDepth) { bestDepth = depth; bestSpine = i; }
                }

                if (bestSpine >= 0)
                {
                    info.spineRoot = bestSpine;
                    // 2) 塌缩目标：head 骨骼（优先 head_0）
                    int head = -1;
                    for (int i = 0; i < numBones; i++)
                    {
                        if (!names[i] || !strstr(names[i], "head")) continue;
                        head = i;
                        if (!strcmp(names[i], "head_0")) break;
                    }
                    info.collapseTarget = (head >= 0) ? head : bestSpine;

                    // 3) 收集 spine 根 + 所有后代（parent 链包含 spine 根）
                    for (int i = 0; i < numBones; i++)
                    {
                        if (!names[i]) continue;
                        if (i == bestSpine) { info.bones.push_back(i); continue; }
                        int p = parents[i];
                        bool isDesc = false;
                        while (p >= 0 && !isDesc && p < numBones && names[p])
                        {
                            if (p == bestSpine) { isDesc = true; break; }
                            p = parents[p];
                        }
                        if (isDesc) info.bones.push_back(i);
                    }
                }
                else
                {
                    // 兜底：无 spine 层级 → 关键词匹配（旧逻辑）
                    for (int i = 0; i < numBones; i++)
                    {
                        if (!names[i]) continue;
                        if (strstr(names[i], "hand") || strstr(names[i], "wrist") ||
                            strstr(names[i], "arm") || strstr(names[i], "clavicle") ||
                            strstr(names[i], "head") || strstr(names[i], "neck"))
                            info.bones.push_back(i);
                    }
                    info.collapseTarget = -1;
                }
            }
            // 记录诊断
            g_boneDiagEnt = ent;
            {
                char b0info[256]; b0info[0] = 0;
                if (numBones > 0 && boneIdx > 0 && boneIdx < 0x400000)
                {
                    BYTE* b0 = phdr + boneIdx;
                    int ni0 = *(int*)(b0 + 0);
                    if (ni0 >= 0 && ni0 <= 0x100000)
                        snprintf(b0info, sizeof(b0info), "bone0='%.32s'", (const char*)(b0 + ni0));
                }
                char spineinfo[256]; spineinfo[0] = 0;
                if (info.spineRoot >= 0)
                {
                    BYTE* s0 = phdr + boneIdx + (size_t)info.spineRoot * BONE_SIZE;
                    int ni = *(int*)(s0 + 0);
                    if (ni >= 0 && ni <= 0x100000)
                        snprintf(spineinfo, sizeof(spineinfo),
                                 "spineRoot=%d('%.32s') target=%d",
                                 info.spineRoot, (const char*)(s0 + ni), info.collapseTarget);
                }
                else
                    snprintf(spineinfo, sizeof(spineinfo), "spineRoot=none(keyword fallback)");
                snprintf(g_boneDiag, sizeof(g_boneDiag),
                         "ent=%d numBones=%d boneIdx=0x%X hide=%d | %s | %s",
                         ent, numBones, boneIdx, (int)info.bones.size(), spineinfo, b0info);
            }
        }
    }
    g_boneCache[ent] = info;
    return g_boneCache[ent];
}

// ---------- SetupBones Detour ----------
static bool __fastcall SetupBonesDetour(void* thisPtr, void* /*edx*/,
                                        float* pBoneToWorldOut, int nMaxBones,
                                        int boneMask, float currentTime)
{
    bool ret = g_original(thisPtr, pBoneToWorldOut, nMaxBones, boneMask, currentTime);

    if (ret && g_enabled && pBoneToWorldOut)
    {
        int ent = *(int*)((char*)thisPtr + OFF_ENTINDEX);
        if (ent >= 1 && ent <= 2048)
        {
            bool isTarget = false;
            {
                std::lock_guard<std::mutex> lock(g_mtx);
                isTarget = (g_boneMap.find(ent) != g_boneMap.end());
            }
            if (isTarget)
            {
                // 骨骼隐藏（Michael CS:S 方法）：spine 根+后代 塌缩到 head
                const BoneHideInfo& bi = GetEntityBones(thisPtr, ent);
                if (!bi.bones.empty())
                {
                    // 塌缩目标位置：head（Michael 方法）或根骨骼0
                    float tx, ty, tz;
                    if (bi.collapseTarget >= 0 && bi.collapseTarget < nMaxBones)
                    {
                        float* t = pBoneToWorldOut + (size_t)bi.collapseTarget * 12;
                        tx = t[3]; ty = t[7]; tz = t[11];
                    }
                    else
                    {
                        tx = pBoneToWorldOut[3];
                        ty = pBoneToWorldOut[7];
                        tz = pBoneToWorldOut[11];
                    }
                    for (int bone : bi.bones)
                    {
                        if (bone <= 0) continue;
                        float* m = pBoneToWorldOut + (size_t)bone * 12;  // 48B = 12 float
                        // MatrixScaleByZero：3×3 归零 → 蒙皮顶点塌缩成一点
                        m[0] = 0; m[1] = 0; m[2] = 0;
                        m[4] = 0; m[5] = 0; m[6] = 0;
                        m[8] = 0; m[9] = 0; m[10] = 0;
                        // 平移到目标点（行0/1/2 平移 = +0xC/+0x1C/+0x2C）
                        m[3] = tx; m[7] = ty; m[11] = tz;
                    }
                    InterlockedIncrement(&g_writes);
                }
            }
        }
    }
    return ret;
}

// ---------- 安装 hook ----------
static bool InstallHook()
{
    if (g_ready) return true;

    HMODULE hClient = GetModuleHandleA("client.dll");
    if (!hClient) return false;
    g_clientBase = (uintptr_t)hClient;

    BYTE* setup = (BYTE*)(g_clientBase + SETUPBONES_RVA);
    // 特征验证（防止版本不匹配）
    if (*(DWORD*)setup != SETUPBONES_MAGIC)
        return false;
    g_setupBones = (uintptr_t)setup;

    // 计算覆盖长度（完整指令）
    g_patchLen = CalcPatchLen(setup);
    if (g_patchLen < 5) g_patchLen = 5;
    if (g_patchLen > 16) g_patchLen = 16;

    // 分配 trampoline：复制原字节 + jmp 回原函数
    g_trampoline = AllocExec(64);
    if (!g_trampoline) return false;

    BYTE* tp = (BYTE*)g_trampoline;
    memcpy(tp, setup, g_patchLen);
    WriteJmp(tp + g_patchLen, setup + g_patchLen);
    g_original = (SetupBonesFn)g_trampoline;

    // 写跳转到 detour（覆盖完整指令，多余字节 NOP）
    DWORD oldProt;
    VirtualProtect(setup, g_patchLen, PAGE_EXECUTE_READWRITE, &oldProt);
    WriteJmp(setup, (void*)&SetupBonesDetour);
    for (int i = 5; i < g_patchLen; i++)
        setup[i] = 0x90;  // NOP
    VirtualProtect(setup, g_patchLen, oldProt, &oldProt);
    FlushInstructionCache(GetCurrentProcess(), setup, g_patchLen);

    g_ready = true;
    return true;
}

// ---------- 读控制文件（SourceMod 写） ----------
static void LoadCtrl()
{
    std::lock_guard<std::mutex> lock(g_mtx);
    g_boneMap.clear();

    // 相对路径 = 游戏 cwd（MIGI=migi\csgo，原版=csgo），与插件 OpenFile 一致
    FILE* f = fopen(CTRL_FILE, "rt");
    if (!f)
    {
        // 兜底：显式 csgo\ 或 migi\csgo\ 子目录
        f = fopen("csgo\\legs_ext_ctrl.txt", "rt");
        if (!f) f = fopen("migi\\csgo\\legs_ext_ctrl.txt", "rt");
    }
    if (!f) { g_enabled = false; return; }

    char line[512];
    bool first = true;
    while (fgets(line, sizeof(line), f))
    {
        char* s = line;
        // 跳过空白/注释
        while (*s == ' ' || *s == '\t') s++;
        if (*s == '\n' || *s == '\r' || *s == '#' || *s == '\0') continue;
        if (first)
        {
            int on = atoi(s);
            g_enabled = (on != 0);
            first = false;
            continue;
        }
        // 实体索引（骨骼由 DLL 运行时 GetEntityBones 解析，忽略行内骨骼列表）
        int ent = atoi(s);
        if (ent >= 1 && ent <= 2048)
            g_boneMap[ent] = std::vector<int>();  // 只标记为目标实体
    }
    fclose(f);
}

// ---------- 写状态文件 ----------
static void WriteState()
{
    FILE* f = fopen(STATE_FILE, "wt");
    if (!f)
    {
        f = fopen("csgo\\legs_ext_state.txt", "wt");
        if (!f) f = fopen("migi\\csgo\\legs_ext_state.txt", "wt");
    }
    if (!f) return;
    fprintf(f, "ready=%d\n", g_ready ? 1 : 0);
    fprintf(f, "base=0x%X\n", (unsigned)g_clientBase);
    fprintf(f, "setupbones=0x%X\n", (unsigned)g_setupBones);
    fprintf(f, "writes=%d\n", (int)g_writes);
    fprintf(f, "enabled=%d\n", g_enabled ? 1 : 0);
    fprintf(f, "entities=%d\n", (int)g_boneMap.size());
    // 骨骼解析诊断
    {
        std::lock_guard<std::mutex> lock(g_cacheMtx);
        if (g_boneDiagEnt > 0)
            fprintf(f, "bone_diag=%s\n", g_boneDiag);
        for (auto& kv : g_boneCache)
        {
            const BoneHideInfo& bi = kv.second;
            if (kv.first >= 1)
                fprintf(f, "bone_ent%d=%d [", kv.first, (int)bi.bones.size());
            for (size_t i = 0; i < bi.bones.size() && i < 12; i++)
                fprintf(f, "%s%d", i ? "," : "", bi.bones[i]);
            if (kv.first >= 1)
                fprintf(f, "]\n");
            if (bi.spineRoot >= 0)
                fprintf(f, "spine_ent%d: root=%d target=%d\n", kv.first, bi.spineRoot, bi.collapseTarget);
        }
    }
    fclose(f);
}

// ---------- 工作线程 ----------
static DWORD WINAPI WorkerThread(LPVOID)
{
    // 等待 client.dll 加载
    for (int i = 0; i < 100 && !GetModuleHandleA("client.dll"); i++)
        Sleep(100);
    if (!GetModuleHandleA("client.dll"))
        return 0;

    InstallHook();
    LoadCtrl();
    WriteState();

    // 周期刷新控制/状态
    DWORD lastCtrl = 0, lastState = 0;
    for (;;)
    {
        Sleep(200);
        DWORD now = GetTickCount();
        if (now - lastCtrl > 200) { LoadCtrl(); lastCtrl = now; }
        if (now - lastState > 1000) { WriteState(); lastState = now; }
    }
    return 0;
}

// ---------- 入口 ----------
BOOL WINAPI DllMain(HINSTANCE hDll, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        DisableThreadLibraryCalls(hDll);
        CreateThread(nullptr, 0, WorkerThread, nullptr, 0, nullptr);
    }
    return TRUE;
}

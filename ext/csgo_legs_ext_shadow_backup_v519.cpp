// ============================================================
// CSGO Legs 注入 DLL —— 看腿骨骼矩阵隐藏（客户端侧）
// 功能：
//   1. 注入到 csgo.exe（32 位）后 GetModuleHandle("client.dll") 拿基址
//   2. Detour hook C_BaseAnimating::SetupBones（client.dll + RVA 0x1D3140）
//   3. 读 SourceMod 写的控制文件 legs_ext_ctrl.txt（腿实体+骨骼索引）
//   4. post-hook 把腿实体 spine 根+后代 骨骼矩阵 3×3 归零并平移到 head 位置
//      → 上半身 mesh 塌成一点消失，腿（pelvis 后代）保留（Michael CS:S 方法）
//   5. 写状态文件 legs_ext_state.txt（hook 就绪/基址/改写次数）
// 偏移（2023 legacy client.dll 逆向确认）：
//   SetupBones          = 基址 + 0x1D3140
//   m_EntIndex          = this + 0x60
//   m_CachedBoneData    = this + 0x2910（矩阵数组指针，48B/骨骼）
//   骨骼数              = this + 0x291C
//   矩阵平移            = +0x0C(x) +0x1C(y) +0x2C(z)
// 控制文件格式（SourceMod 写）：
//   第1行: 开关(1=开 0=关)
//   之后每行: 实体索引,骨骼1,骨骼2,...   （腿实体 + 要隐藏的骨骼索引）
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
#define BONE_STRIDE          48

// ★ v5.3 客户端阴影屏蔽（capstone 逆向确认）
// ⚠️ v5.15 重大修正：m_fEffects 偏移 = +0xEC（反汇编 0x1CF010 = C_BaseEntity::ShadowCastType
//    确认 `test byte ptr [ebx+0xEC], 0x30`），不是 +0x10！之前 EF_NOSHADOW 一直写错位置
#define OFF_EFFECTS          0xEC     // 客户端 C_BaseEntity::m_fEffects（0x1CF010 反汇编确认）
#define EF_NOSHADOW_VAL      0x010    // 不投阴影（ShadowCastType 检查 0x30=EF_NODRAW|EF_NOSHADOW）
#define EF_NOCSM_VAL         0x4000   // 不渲染进级联阴影深度图（public/const.h）
#define EF_NOSHADOWDEPTH_VAL 0x800    // 不渲染进任何阴影深度图（public/const.h）

// ★ v5.7/v5.8 客户端阴影（本地 cstrike15_src 源码 + client.dll 反汇编确认）
//   C_BaseEntity::CreateShadow @0x1EA590：m_ShadowHandle=[this+0x2E2] word、m_ShadowBits=[this+0x2E4]
//   ShadowCastType 虚调用 = [ *(this+4) + 0x70 ] 即 vtable[28]
//   mgr->CreateShadow = vtable[16] (0x27DDE0, 4参 ret 0x10)；mgr->DestroyShadow = vtable[17] (0x27E180, 1参 ret 4)
// ⚠️ v5.8 重大修正：MGR_PTR_RVA 之前误用编译时 VA 0x14E35D08（ImageBase=0x10000000）
//    → 运行时 g_clientBase+0x14E35D08 访问未映射内存导致闪退！正确 RVA = 0x14E35D08-0x10000000 = 0x4E35D08
// ⚠️ 腿实体 vtable[28] 实测 = 0xBD3E0（mov eax,ecx;ret 返回 this，非 ShadowCastType）→ 腿实体 vtable 布局待确认
#define OFF_VTABLE           4         // vtable 指针在 this+4（mov eax,[ecx+4]; add ecx,4）
#define SHADOWCAST_SLOT      28        // ShadowCastType = vtable[28]（C_BaseEntity；腿实体实测非此）
#define OFF_SHADOWHANDLE     0x2E2     // C_BaseEntity::m_ShadowHandle (word, INVALID=0xFFFF)
#define OFF_SHADOWBITS       0x2E4     // C_BaseEntity::m_ShadowBits (dword)
#define MGR_PTR_RVA          0x4E35D08 // g_pClientShadowMgr 全局（RVA，ImageBase=0x10000000；VA=0x14E35D08）— 已确认
#define MGR_CREATESHADOW_SLOT 16       // CreateShadow (4 参数 ret 0x10)
#define MGR_DESTROYSHADOW_SLOT 17      // DestroyShadow (1 参数 ret 4)
typedef void(__thiscall *DestroyShadowFn)(void* mgr, unsigned short handle);
static volatile long g_shadowDestroyed = 0;   // 诊断：销毁次数
static volatile long g_shadowDestroyCalls = 0; // (v5.8 不调用，保留计数)
static unsigned int g_vtableBaseRva = 0;      // 腿实体 vtable 基址 RVA（*(thisPtr+4)）
static unsigned int g_entSlots[16];           // 腿实体 vtable[24..39] 函数 RVA
static int g_entSlotsValid = 0;               // 槽位已采集标志
static unsigned int g_shadowCastRva = 0;      // 腿实体 vtable[28] (ShadowCastType) 函数 RVA
static unsigned int g_mgrCreateRva = 0;       // mgr vtable[16]
static unsigned int g_mgrDestroyRva = 0;      // mgr vtable[17]
// ★ v5.6 槽位诊断数据
static unsigned int g_slotBytes[21];   // vtable[24..44] 前 4 字节
static unsigned int g_slotBytes2[21];  // vtable[24..44] 第二 4 字节
static unsigned short g_shadowHandleNow = 0xFFFF;
static unsigned int g_shadowBitsNow = 0;
// ★ v5.10 SEH 诊断（每项读取用 __try/__except 保护：崩溃不闪退，记录偏移）
#define SEH_OK       1
#define SEH_CRASH   -1
#define SEH_SKIP     0
static int  g_seh[8];                  // 8 项诊断结果
static int  g_crashOff = 0;            // 崩溃偏移（0=无）
static unsigned int g_pMgrVal = 0;     // mgr 对象地址
static int  g_sehDone = 0;             // 诊断已完成标志
// ★ v5.11：运行时验证腿实体 GetShadowCastType(vtable[28]) 返回值 + mgr 槽位（修正后）
typedef int(__thiscall *ShadowCastFn)(void* self);
static int g_shadowCastRet = 0x7FFFFFFF;   // 调用 vtable[28] 的返回值
static unsigned int g_mgrVtBase = 0;       // mgr vtable 基址 RVA（= *(mgr对象)）
static unsigned int g_mgrCreate2 = 0;      // mgr vtable[16]（修正读取）
static unsigned int g_mgrDestroy2 = 0;     // mgr vtable[17]（修正读取）
// ★ v5.12 per-instance vtable 劫持（根治阴影：克隆腿实体 vtable，槽位[28]=GetShadowCastType 返回 0）
static volatile long g_vtHijacked = 0;     // 已劫持标志
static unsigned int g_cloneVtRva = 0;      // 克隆 vtable 地址 RVA
static int g_vtLen = 0;                    // 克隆 vtable 长度（槽数）
static uintptr_t g_clientSize = 0;         // client.dll 映像大小（运行时）
// ★ v5.13：扫描 thisPtr+0..0x10 的 vtable 候选，调用[28]测试返回值，劫持真正 GetShadowCastType 的
static unsigned int g_vtCand[5];           // 候选 vtable RVA（偏移 0/4/8/0xC/0x10）
static int g_retCand[5];                   // 各候选 vtable[28] 调用返回值（0x7FFFFFFF=未测/崩）
static int g_hijackOff = -1;               // 实际劫持的指针偏移
// ★ v5.14：hook C_BaseEntity::CreateShadow(0x1EA590) 确认它用的 this/vtable/GetShadowCastType 返回值
#define CREATESHADOW_RVA     0x1EA590
#define CREATESHADOW_MAGIC   0x83EC8B55   // 55 8B EC 83 EC 08（v5.15 修正：之前误写 0x08EC8B55 导致 hook 未安装）
static void* g_origCreateShadow = nullptr;
static unsigned int g_csThisPtr = 0;       // CreateShadow 的 this
static unsigned int g_csVtRva = 0;         // CreateShadow 用的 vtable（*(this+4)）
static int g_csShadowCastRet = 0x7FFFFFFF; // CreateShadow 内调用 GetShadowCastType 返回值
static unsigned int g_csShadowBits = 0;    // CreateShadow 入口 m_ShadowBits(+0x2E4)
static unsigned short g_csHandle = 0xFFFF; // CreateShadow 入口 m_ShadowHandle(+0x2E2)
static unsigned int g_setupBonesThis = 0;  // 最近一次 SetupBones 的 thisPtr（对比用）
static volatile long g_effWritten = 0;     // v5.16 效果位已写入标志（避免每帧写入）
// ★ v5.18：收集所有实体的 ShadowCastType(vtable[28]) 变体（去重，收集满即停，零持续开销）
static unsigned int g_scObs[16];           // 不同 ShadowCastType 函数 RVA
static int g_scObsN = 0;                   // 已收集数量
// ★ v5.15：扫描 mgr->m_Shadows 找腿实体 shadow handle（m_Shadows=[mgr+0x2C]，元素0x114，首字段m_pOwner）
static int  g_shadowScanDone = 0;          // 扫描完成标志
static int  g_foundHandle = -1;            // 找到的 shadow handle
static int  g_mShadowsPtr = 0;             // m_Shadows 数组指针（诊断）
static int  g_shadowScanCnt = 0;           // 扫描的条目数
static volatile long g_destroyed2 = 0;     // 已 DestroyShadow 标志
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
static std::map<int, std::vector<int>> g_boneMap;  // 实体索引 -> 骨骼索引列表
static volatile bool g_enabled = false;
static volatile long g_writes = 0;
static volatile bool g_ready = false;
static uintptr_t g_clientBase = 0;
static uintptr_t g_setupBones = 0;

// ★ v5.4 诊断：m_fEffects 偏移验证（确认 +0x10 是不是 m_fEffects）
static int  g_diagFx[8];
static int  g_diagFxEnt = 0;
static int  g_diagFxCount = 0;

// 取进程当前目录（csgo.exe 的 cwd = 游戏根目录，MIGI 模式 = migi\csgo）
// 实际用模块路径所在目录更稳：直接尝试 csgo\ 和 migi\csgo\ 两个相对路径

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

// ---------- Hook 函数（detour 目标） ----------
// 从客户端实体运行时解析骨骼层级（缓存，不依赖插件 MDL 解析）
// this+0x294C = CStudioHdr*, +0 = studiohdr_t*, +0x9C=numbones, +0xA0=boneindex
// 隐藏策略（Michael CS:S 方法）：
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

// ★ v5.12：GetShadowCastType 返回 SHADOWS_NONE(0) 的 stub（替换腿实体 vtable[28]）
static int __fastcall ShadowCastNone(void* thisPtr, void* /*edx*/)
{
    return 0;   // SHADOWS_NONE → CreateShadow 里 m_ShadowBits 全清 → 自动 DestroyShadow，不再创建
}

// ★ v5.13：per-instance vtable 劫持（v5.12 劫持 thisPtr+4 未生效 → 扫描 thisPtr+0..0x10 所有 vtable 指针，
//   逐个调用 [28] 测试返回值，劫持真正返回非0 的 GetShadowCastType 所在 vtable）
static void HijackLegsVtable(void* thisPtr)
{
    if (g_vtHijacked) return;
    if (!g_clientBase || !g_clientSize) return;

    for (int off = 0; off <= 0x10; off += 4)
    {
        void** vt = *(void***)((char*)thisPtr + off);
        g_vtCand[off / 4] = 0;
        g_retCand[off / 4] = 0x7FFFFFFF;
        if (!vt) continue;
        uintptr_t vtp = (uintptr_t)vt;
        if (vtp < g_clientBase || vtp >= g_clientBase + g_clientSize) continue;
        g_vtCand[off / 4] = (unsigned)((BYTE*)vt - (BYTE*)g_clientBase);

        // 调用 vtable[28] 测试（SEH 保护，this 参数 = 子对象地址 thisPtr+off）
        int ret = 0x7FFFFFFF;
        __try {
            void* fn = vt[SHADOWCAST_SLOT];
            if (fn)
                ret = ((ShadowCastFn)fn)((char*)thisPtr + off);
        } __except(EXCEPTION_EXECUTE_HANDLER) { ret = 0x7FFFFFFF; }
        g_retCand[off / 4] = ret;

        // 返回非0 → 这就是 GetShadowCastType（CreateShadow 用它判断投阴影）→ 劫持它
        if (ret != 0 && ret != 0x7FFFFFFF)
        {
            // 扫描 vtable 长度：连续 4 个指针不在 client.dll 模块内则视为结束
            int len = 0, bad = 0;
            for (int s = 0; s < 400; s++)
            {
                uintptr_t p = (uintptr_t)vt[s];
                bool valid = (p >= g_clientBase && p < g_clientBase + g_clientSize);
                if (!valid) { if (++bad >= 4) break; }
                else { bad = 0; len = s + 1; }
            }
            if (len < 40) continue;

            // 克隆 vtable 到新内存（RW 即可，只是指针数组）
            void** vtNew = (void**)VirtualAlloc(nullptr, (size_t)len * 4, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
            if (!vtNew) continue;
            memcpy(vtNew, vt, (size_t)len * 4);

            // 槽位[28] = GetShadowCastType → 改成返回 0（SHADOWS_NONE）
            vtNew[SHADOWCAST_SLOT] = (void*)&ShadowCastNone;

            // 写回腿实体对应偏移的 vtable 指针
            *(void***)((char*)thisPtr + off) = vtNew;

            g_vtHijacked = 1;
            g_cloneVtRva = (unsigned)((BYTE*)vtNew - (BYTE*)g_clientBase);
            g_vtLen = len;
            g_hijackOff = off;
            break;
        }
    }
}

// ★ v5.14：hook C_BaseEntity::CreateShadow —— 记录它用的 this/vtable/GetShadowCastType返回值/m_ShadowBits
//   确认劫持是否真的影响 CreateShadow 的阴影创建路径
typedef void(__thiscall *CreateShadowFn)(void* thisPtr);
static void __fastcall CreateShadowDetour(void* thisPtr, void* /*edx*/)
{
    // ★ v5.17 回退：不写任何效果位（之前对【所有实体】写 +0xEC |= 0x4810 导致模型全消失）
    __try {
        g_csThisPtr = (unsigned)thisPtr;
        void** vt = *(void***)((char*)thisPtr + OFF_VTABLE);
        if (vt)
        {
            g_csVtRva = (unsigned)((BYTE*)vt - (BYTE*)g_clientBase);
            void* fn = vt[SHADOWCAST_SLOT];
            if (fn)
                g_csShadowCastRet = ((ShadowCastFn)fn)((char*)thisPtr + OFF_VTABLE);
        }
        g_csShadowBits = *(unsigned int*)((char*)thisPtr + OFF_SHADOWBITS);
        g_csHandle = *(unsigned short*)((char*)thisPtr + OFF_SHADOWHANDLE);
    } __except(EXCEPTION_EXECUTE_HANDLER) {}
    ((CreateShadowFn)g_origCreateShadow)(thisPtr);
}

static bool __fastcall SetupBonesDetour(void* thisPtr, void* /*edx*/,
                                        float* pBoneToWorldOut, int nMaxBones,
                                        int boneMask, float currentTime)
{
    g_setupBonesThis = (unsigned)thisPtr;   // ★ v5.14 记录 SetupBones 的 this（对比 CreateShadow 的 this）
    // ★ v5.18 收集所有 ShadowCastType 变体（去重；g_scObsN 满 16 后零开销）
    if (g_scObsN < 16)
    {
        __try {
            for (int off = 0; off <= 4; off += 4)
            {
                void** vt = *(void***)((char*)thisPtr + off);
                if (vt && vt[SHADOWCAST_SLOT])
                {
                    unsigned int rva = (unsigned)((BYTE*)vt[SHADOWCAST_SLOT] - (BYTE*)g_clientBase);
                    bool dup = false;
                    for (int k = 0; k < g_scObsN; k++)
                        if (g_scObs[k] == rva) { dup = true; break; }
                    if (!dup && g_scObsN < 16)
                        g_scObs[g_scObsN++] = rva;
                }
            }
        } __except(EXCEPTION_EXECUTE_HANDLER) {}
    }
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
                // ★ v5.17 回退：移除效果位写入（+0xEC |= 0x4810 破坏渲染字段导致模型消失）
                // ★ v5.10 SEH 保护诊断：逐项尝试阴影相关读取，崩溃被 __try/__except 捕获（不闪退）
                //   项0=EF_NOSHADOW写+0x10  项1=vtable基址+槽位  项2=mgr指针+槽位
                //   项3=m_ShadowHandle+0x2E2  项4=m_ShadowBits+0x2E4  项5=diag(+0x0C..0x38)
                if (!g_sehDone)
                {
                    __try {
                        *(int*)((char*)thisPtr + OFF_EFFECTS) |= EF_NOSHADOW_VAL;
                        g_seh[0] = SEH_OK;
                    } __except(EXCEPTION_EXECUTE_HANDLER) { g_seh[0] = SEH_CRASH; g_crashOff = OFF_EFFECTS; }

                    __try {
                        void** vtEnt = *(void***)((char*)thisPtr + OFF_VTABLE);
                        if (vtEnt)
                        {
                            g_vtableBaseRva = (unsigned)((BYTE*)vtEnt - (BYTE*)g_clientBase);
                            for (int s = 24; s <= 39; s++)
                            {
                                if (vtEnt[s])
                                    g_entSlots[s - 24] = (unsigned)((BYTE*)vtEnt[s] - (BYTE*)g_clientBase);
                                else
                                    g_entSlots[s - 24] = 0;
                            }
                            g_shadowCastRva = g_entSlots[28 - 24];
                        }
                        g_seh[1] = SEH_OK;
                    } __except(EXCEPTION_EXECUTE_HANDLER) { g_seh[1] = SEH_CRASH; g_crashOff = 0x10004; }

                    __try {
                        // ★ v5.11 修正：0x4E35D08 是 mgr 对象地址（非存指针的全局）！
                        //   正确：mgr对象=base+0x4E35D08，vtable=*(mgr对象)
                        void* pMgr = (char*)g_clientBase + MGR_PTR_RVA;
                        g_pMgrVal = (unsigned)pMgr;
                        void** vtMgr = *(void***)pMgr;   // mgr vtable = *(对象)  ← 之前多解引用导致崩溃
                        if (vtMgr)
                        {
                            g_mgrVtBase = (unsigned)((BYTE*)vtMgr - (BYTE*)g_clientBase);
                            if (vtMgr[MGR_CREATESHADOW_SLOT])
                                g_mgrCreate2 = (unsigned)((BYTE*)vtMgr[MGR_CREATESHADOW_SLOT] - (BYTE*)g_clientBase);
                            if (vtMgr[MGR_DESTROYSHADOW_SLOT])
                                g_mgrDestroy2 = (unsigned)((BYTE*)vtMgr[MGR_DESTROYSHADOW_SLOT] - (BYTE*)g_clientBase);
                            for (int s = 24; s <= 44; s++)
                            {
                                if (vtMgr[s])
                                {
                                    g_slotBytes[s - 24] = *(unsigned int*)vtMgr[s];
                                    g_slotBytes2[s - 24] = *(unsigned int*)((BYTE*)vtMgr[s] + 4);
                                }
                            }
                        }
                        g_seh[2] = SEH_OK;
                    } __except(EXCEPTION_EXECUTE_HANDLER) { g_seh[2] = SEH_CRASH; g_crashOff = 0x20000; }

                    __try {
                        g_shadowHandleNow = *(unsigned short*)((char*)thisPtr + OFF_SHADOWHANDLE);
                        g_seh[3] = SEH_OK;
                    } __except(EXCEPTION_EXECUTE_HANDLER) { g_seh[3] = SEH_CRASH; g_crashOff = OFF_SHADOWHANDLE; }

                    __try {
                        g_shadowBitsNow = *(unsigned int*)((char*)thisPtr + OFF_SHADOWBITS);
                        g_seh[4] = SEH_OK;
                    } __except(EXCEPTION_EXECUTE_HANDLER) { g_seh[4] = SEH_CRASH; g_crashOff = OFF_SHADOWBITS; }

                    __try {
                        g_diagFx[0] = *(int*)((char*)thisPtr + 0x0C);
                        g_diagFx[1] = *(int*)((char*)thisPtr + 0x10);
                        g_diagFx[2] = *(int*)((char*)thisPtr + 0x14);
                        g_diagFx[3] = *(int*)((char*)thisPtr + 0x18);
                        g_diagFx[4] = *(int*)((char*)thisPtr + 0x2C);
                        g_diagFx[5] = *(int*)((char*)thisPtr + 0x30);
                        g_diagFx[6] = *(int*)((char*)thisPtr + 0x34);
                        g_diagFx[7] = *(int*)((char*)thisPtr + 0x38);
                        g_diagFxEnt = ent;
                        g_diagFxCount = 1;
                        g_seh[5] = SEH_OK;
                    } __except(EXCEPTION_EXECUTE_HANDLER) { g_seh[5] = SEH_CRASH; g_crashOff = 0x0C; }

                    // ★ v5.11 项6：运行时调用腿实体 GetShadowCastType(vtable[28])，验证是否永远返回非0
                    //   返回 0=SHADOWS_NONE(不投)  非0=投阴影 → 若非0则 EF_NOSHADOW 无效的根因确认
                    __try {
                        void** vtEnt = *(void***)((char*)thisPtr + OFF_VTABLE);
                        if (vtEnt && vtEnt[SHADOWCAST_SLOT])
                        {
                            ShadowCastFn fn = (ShadowCastFn)vtEnt[SHADOWCAST_SLOT];
                            g_shadowCastRet = fn((char*)thisPtr + OFF_VTABLE);  // 与 CreateShadow 相同的 this（this+4）
                        }
                        g_seh[6] = SEH_OK;
                    } __except(EXCEPTION_EXECUTE_HANDLER) { g_seh[6] = SEH_CRASH; g_crashOff = 0x30000; }

                    g_sehDone = 1;
                }
                // ★ v5.12 根治：per-instance vtable 劫持（克隆腿实体 vtable，槽位[28]→返回0）
                HijackLegsVtable(thisPtr);
                // ★ v5.15：扫描 mgr->m_Shadows 找腿实体的 shadow handle → DestroyShadow（直接消灭）
                //   m_Shadows=[mgr+0x2C]，元素 0x114B，首字段 m_pOwner=IClientRenderable*
                if (!g_shadowScanDone)
                {
                    __try {
                        void* pMgr = (char*)g_clientBase + MGR_PTR_RVA;
                        void* pShadows = *(void**)((char*)pMgr + 0x2C);
                        g_mShadowsPtr = (int)pShadows;
                        if (pShadows)
                        {
                            // 候选 owner：thisPtr 附近（SetupBones this = IClientRenderable 子对象）
                            unsigned int cands[5] = {
                                (unsigned)thisPtr,
                                (unsigned)((char*)thisPtr - 4),
                                (unsigned)((char*)thisPtr + 4),
                                (unsigned)((char*)thisPtr + 8),
                                (unsigned)((char*)thisPtr + 0xC)
                            };
                            for (int h = 0; h < 4096; h++)
                            {
                                void* owner = *(void**)((char*)pShadows + (size_t)h * 0x114);
                                if (!owner) { g_shadowScanCnt = h; break; }
                                g_shadowScanCnt = h + 1;
                                for (int c = 0; c < 5; c++)
                                {
                                    if ((unsigned)owner == cands[c])
                                    {
                                        g_foundHandle = h;
                                        break;
                                    }
                                }
                                if (g_foundHandle != -1) break;
                            }
                        }
                    } __except(EXCEPTION_EXECUTE_HANDLER) { g_foundHandle = -2; }
                    g_shadowScanDone = 1;
                }
                // 找到 handle → 直接 DestroyShadow（vtable[17]，1 参数）
                if (g_foundHandle >= 0 && !g_destroyed2)
                {
                    __try {
                        void* pMgr = (char*)g_clientBase + MGR_PTR_RVA;
                        void** vt = *(void***)pMgr;
                        if (vt && vt[MGR_DESTROYSHADOW_SLOT])
                        {
                            ((DestroyShadowFn)vt[MGR_DESTROYSHADOW_SLOT])(pMgr, (unsigned short)g_foundHandle);
                            g_destroyed2 = 1;
                        }
                    } __except(EXCEPTION_EXECUTE_HANDLER) {}
                }
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
    // client.dll 映像大小（vtable 长度扫描用）
    {
        IMAGE_DOS_HEADER* dos = (IMAGE_DOS_HEADER*)hClient;
        IMAGE_NT_HEADERS* nt = (IMAGE_NT_HEADERS*)((BYTE*)hClient + dos->e_lfanew);
        g_clientSize = nt->OptionalHeader.SizeOfImage;
    }

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

    // ★ v5.14 hook C_BaseEntity::CreateShadow（诊断 this/vtable，不改变行为）
    {
        BYTE* cs = (BYTE*)(g_clientBase + CREATESHADOW_RVA);
        if (*(DWORD*)cs == CREATESHADOW_MAGIC)
        {
            void* tramp = AllocExec(64);
            if (tramp)
            {
                int len = CalcPatchLen(cs);
                if (len < 5) len = 5;
                BYTE* tp = (BYTE*)tramp;
                memcpy(tp, cs, len);
                WriteJmp(tp + len, cs + len);
                g_origCreateShadow = tramp;
                DWORD oldProt2;
                VirtualProtect(cs, len, PAGE_EXECUTE_READWRITE, &oldProt2);
                WriteJmp(cs, (void*)&CreateShadowDetour);
                for (int i = 5; i < len; i++) cs[i] = 0x90;
                VirtualProtect(cs, len, oldProt2, &oldProt2);
                FlushInstructionCache(GetCurrentProcess(), cs, len);
            }
        }
    }

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
    // ★ v5.10 SEH 诊断输出（1=成功 -1=崩溃被捕获 0=未执行）
    fprintf(f, "seh_diag: ");
    for (int i = 0; i < 8; i++)
        fprintf(f, "[%d]=%d ", i, g_seh[i]);
    fprintf(f, "\n");
    fprintf(f, "crash_off=0x%X pMgr_val=0x%X\n", g_crashOff, g_pMgrVal);
    // ★ v5.11 修正后 mgr：对象地址→vtable=*(对象)
    fprintf(f, "mgr_vt_base_rva=0x%X CreateShadow[16]=0x%X DestroyShadow[17]=0x%X\n",
            g_mgrVtBase, g_mgrCreate2, g_mgrDestroy2);
    fprintf(f, "shadowcast_ret=%d (0x%X)  <-- 腿实体 GetShadowCastType(vtable[28]) 返回值\n",
            g_shadowCastRet, g_shadowCastRet);
    // ★ v5.12 劫持状态
    fprintf(f, "vt_hijacked=%d clone_vt_rva=0x%X vt_len=%d hijack_off=%d\n",
            (int)g_vtHijacked, g_cloneVtRva, g_vtLen, g_hijackOff);
    // ★ v5.13 候选 vtable 测试（偏移 0/4/8/0xC/0x10 的 vtable[28] 返回值）
    fprintf(f, "vt_cand: ");
    for (int i = 0; i < 5; i++)
        fprintf(f, "[+0x%X]=0x%X/ret=%d ", i * 4, g_vtCand[i], g_retCand[i]);
    fprintf(f, "\n");
    // ★ v5.14 CreateShadow 诊断：this / vtable / GetShadowCastType返回值 / bits / handle / SetupBones this
    fprintf(f, "createshadow: this=0x%X vt=0x%X castRet=%d bits=0x%X handle=0x%X | setupbones_this=0x%X\n",
            g_csThisPtr, g_csVtRva, g_csShadowCastRet, g_csShadowBits, g_csHandle, g_setupBonesThis);
    // ★ v5.18 所有 ShadowCastType 变体（反汇编确认 C_CSPlayer::ShadowCastType）
    fprintf(f, "sc_obs[%d]: ", g_scObsN);
    for (int i = 0; i < g_scObsN; i++)
        fprintf(f, "[%d]=0x%X ", i, g_scObs[i]);
    fprintf(f, "\n");
    fprintf(f, "ent_vtable_base_rva=0x%X\n", g_vtableBaseRva);
    fprintf(f, "ent_slots[24..39]: ");
    for (int s = 0; s < 16; s++)
        fprintf(f, "[%d]=0x%X ", 24 + s, g_entSlots[s]);
    fprintf(f, "\n");
    fprintf(f, "shadowcast_fn_rva=0x%X\n", g_shadowCastRva);
    fprintf(f, "mgr_rva: CreateShadow[16]=0x%X DestroyShadow[17]=0x%X\n", g_mgrCreateRva, g_mgrDestroyRva);
    fprintf(f, "m_ShadowHandle(+0x2E2)=0x%X m_ShadowBits(+0x2E4)=0x%X\n", g_shadowHandleNow, g_shadowBitsNow);
    if (g_diagFxCount > 0)
        fprintf(f, "diag: +0x0C=0x%X +0x10=0x%X +0x14=0x%X +0x18=0x%X +0x2C=0x%X +0x30=0x%X\n",
                g_diagFx[0], g_diagFx[1], g_diagFx[2], g_diagFx[3], g_diagFx[4], g_diagFx[5]);
    fprintf(f, "mgr_slots: ");
    for (int s = 0; s < 21; s++)
        fprintf(f, "[%d]=%08X%08X ", 24 + s, g_slotBytes[s], g_slotBytes2[s]);
    fprintf(f, "\n");
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

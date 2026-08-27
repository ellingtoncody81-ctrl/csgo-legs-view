#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>

#pragma newdecls required

// ============================================================
// CSGO Legs v1.0 —— CS1.6 showing_feet 思路移植
//
// CS1.6 做法（showing_feet.sma）：把玩家 pev_gaitsequence（走路序列）
//   + framerate 直接塞进实体网络状态 → 客户端按它渲染 → 腿走路摆动
// CS:GO 对应物：走路动画在 overlay 层，主序列是 idle。
//   所以：从玩家 overlay 提取 active 层(weight最大)序列 = gaitsequence，
//   设给实体主序列 + 同步 cycle/pose + StudioFrameAdvance（Aimbot 验证组合）
//
// 参考：
//   - CSGO_PlayerClone.sp / CSGO_Aimbot.sp（Pelipoika）
//     实体 monster_generic / ResetSequence / overlay复制 / StudioFrameAdvance
//   - 签名硬编码自 CSGO_Aimbot.sp（官方 CS:GO x86 引擎）
// ============================================================

#define EFL_DONTBLOCKLOS			(1<<25)
#define EF_NODRAW				0x020
#define EF_BONEMERGE			(1 << 0)
#define EF_PARENT_ANIMATES		(1 << 9)
#define EF_NOSHADOW				(1 << 4)   // ★ v5.3 修正回: 0x010（nillerusr 引擎正确值；v5.2 错改 1<<7 实为 EF_BONEMERGE_FASTCULL）
#define EF_NORECEIVESHADOW		(1 << 6)   // ★ v5.3 修正回: 0x040
#define EF_NOSHADOWDEPTH		(1 << 11)  // ★ v5.19 新增: 0x800 不渲染进任何阴影深度图（L4D 腿部脚本同款）
#define EF_SHADOWDEPTH_NOCACHE	(1 << 12)  // ★ v5.19 新增: 0x1000 阴影深度不缓存
#define EF_NOCSM				(1 << 14)  // ★ v5.19 新增: 0x4000 不渲染进级联阴影深度图（CSM，public/const.h 确认）

#define NUM_LAYERS				12
#define CAnimationLayer_Size	0x5C

// ★ 2023 legacy CAnimationLayer 真实布局（2018 官方源码 cstrike15_src 确认，2023 兼容）
//   m_fFlags@0x00, m_nSequence@0x08, m_flCycle@0x0C, m_flPlaybackRate@0x10,
//   m_flPrevCycle@0x14, m_flWeight@0x18, m_nOrder@0x4C(顺序映射！), m_pOwnerEntity@0x58
//   ⚠️ 之前逆向误判 0x2C/0x28 是 m_flKillDelay/KillRate，不是 cycle/rate！
#define LAYER_SEQ		0x08
#define LAYER_CYCLE		0x0C
#define LAYER_RATE		0x10
#define LAYER_PREVCYC	0x14
#define LAYER_WEIGHT	0x18
#define LAYER_FLAGS		0x00
#define LAYER_ORDER		0x4C   // m_nOrder：层语义顺序映射（GetAnimOverlay 用）

// ★ v3.0 骨骼矩阵隐藏（手/头缩进身体）——客户端 SetupBones hook
//   client.dll C_BaseAnimating::SetupBones 逆向确认（2023 legacy）：
//     - m_EntIndex = this+0x60
//     - SetupBones 返回前从 m_CachedBoneData(this+0x2910) memcpy 到 pBoneToWorldOut
//     - 缓存重算条件 m_iMostRecentModelBoneCounter(this+0x268C) != g_iModelBoneCounter(0x15332374)
//     - 走路动画不 invalidate → 改写一次持续生效
//   方法：dhooks detour hook SetupBones，post 改写腿实体 hand/head 骨骼矩阵平移
//         到根骨骼位置 → 手/头 mesh 缩进身体内部
#define CLIENT_ENTINDEX_OFF     0x60    // 客户端 C_BaseEntity::m_EntIndex
#define BONE_MATRIX_STRIDE      48      // matrix3x4a_t 每骨骼 48 字节
#define BONE_TRANS_X            0x0C    // 矩阵平移 x
#define BONE_TRANS_Y            0x1C    // 矩阵平移 y
#define BONE_TRANS_Z            0x2C    // 矩阵平移 z
#define MAX_HIDE_BONES          12      // 每实体最多隐藏骨骼数

int g_iLegsRef[MAXPLAYERS + 1];
int g_iWeaponRef[MAXPLAYERS + 1];   // ★ v2.31: 武器 prop_dynamic 引用（影子带枪）
int g_iLegsOwner[2048 + 1];
bool g_bLegsEnabled[MAXPLAYERS + 1];
bool g_bSDKReady;
float g_flWalkDist[MAXPLAYERS + 1];   // 位移积分（步态相位）
int g_iWalkSeq[MAXPLAYERS + 1];      // 缓存的有效移动序列（防提取失败闪回0）
int g_iOverlayOffset;                // ★ v2.11: 缓存 FindDataMapInfo 成功偏移（防间歇失败→overlay=NULL）
bool g_bOverlayDiagLogged;           // ★ v2.23: overlay 失败诊断只记一次

Handle g_hResetSequence;
Handle g_hAllocateLayer;
Handle g_hStudioFrameAdvance;

// ★ v3.0 骨骼隐藏状态
Handle g_hSetupBonesDetour;                 // SetupBones detour
bool g_bBoneHideReady;                      // detour 初始化成功
int g_iHideBones[MAXPLAYERS + 1][MAX_HIDE_BONES];  // 每玩家腿实体要隐藏的骨骼索引
int g_iHideBoneCount[MAXPLAYERS + 1];       // 每玩家隐藏骨骼数
int g_iBoneHideEnt[2048 + 1];               // 实体索引 -> 玩家(0=非目标)，回调快速路径
StringMap g_hBoneCache;                     // 模型路径 -> 逗号分隔骨骼索引（缓存）
ConVar g_cvHideBones;                       // sm_legs_hide_bones: 1开 0关
ConVar g_cvWeapon;                          // sm_legs_weapon: 腿实体带枪 1开 0关(默认)
int g_iHookLayout;                          // SetupBones 参数布局（0=未知 1=this@P1 2=this@P2）
bool g_bBoneDiagLogged;                     // 骨骼解析诊断已记录

// ★ v2.33 位置参数（仿 L4D2 Survivor Legs 六参数机制）
//   旧: offset(向下)/forward(沿视线前移)/pitch(俯仰) —— 兼容保留
//   新: off_x/off_y/off_z(局部偏移) + rot_pitch/rot_yaw/rot_roll(旋转)
ConVar g_cvOffset;
ConVar g_cvForward;
ConVar g_cvPitch;
ConVar g_cvRotPitch;   // ★ v2.35: sm_legs_rot_pitch（与 rot_yaw/rot_roll 命名统一）
ConVar g_cvOffX;
ConVar g_cvOffY;
ConVar g_cvOffZ;
ConVar g_cvRotYaw;
ConVar g_cvRotRoll;
ConVar g_cvBody;       // ★ v2.36: m_nBody 强制值(-1=自动)
ConVar g_cvHideUpper;  // ★ v2.36: 自动隐藏上半身/手臂(1开 0关)
StringMap g_hBodyCache;  // ★ v2.37: 模型路径 -> m_nBody 值缓存（v3.1 已禁用，代码保留）
#pragma unused g_hBodyCache
ConVar g_cvAnimTick;
ConVar g_cvSDK;
ConVar g_cvCSAnim;
ConVar g_cvAnimRate;
ConVar g_cvStride;
ConVar g_cvCycleMode;
ConVar g_cvGroundSpeed;
ConVar g_cvTestSeq;   // ★ v2.14: CT动画序列测试(0=关闭 >0=锁定该全局序列播放)

Handle g_hDbgTimer;

public Plugin myinfo =
{
	name = "CSGO Legs v1.0",
	author = "CS1.6 gaitsequence 思路移植 + Pelipoika PlayerClone",
	description = "See your legs in first person (CS:GO)",
	version = "1.0.0",
	url = ""
};

public void OnPluginStart()
{
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("player_team", Event_PlayerTeam);
	
	RegConsoleCmd("sm_legs", Cmd_Legs, "切换第一人称看腿");
	RegConsoleCmd("sm_legs_dbg", Cmd_LegsDbg, "打印动画状态诊断(走路时用)");
	
	g_cvOffset = CreateConVar("sm_legs_offset", "0.0", "[旧]腿实体向下偏移(相对脚底,可负)");
	g_cvForward = CreateConVar("sm_legs_forward", "0.0", "[旧]腿实体向前偏移(0=默认)");
	g_cvPitch = CreateConVar("sm_legs_pitch", "-89.0", "[旧]腿实体俯仰旋转(让腿朝下, L4D2 默认 -89)");
	g_cvRotPitch = CreateConVar("sm_legs_rot_pitch", "-89.0", "俯仰旋转(绕右轴, 让腿朝下; 与旧 sm_legs_pitch 等价)");
	// ★ v2.33 仿 L4D2 Survivor Legs：局部偏移(相对玩家朝向) + 三轴旋转
	//   默认值抄 L4D2(off_z=-20, rot_pitch=-89)：完整模型下压+前倾 → 上半身/手臂被压出视野, 只看腿
	g_cvOffX = CreateConVar("sm_legs_off_x", "0.0", "局部左右偏移(相对玩家朝向, +右 -左)");
	g_cvOffY = CreateConVar("sm_legs_off_y", "0.0", "局部前后偏移(+前 -后, 叠加旧 forward)");
	g_cvOffZ = CreateConVar("sm_legs_off_z", "-20.0", "局部上下偏移(+上 -下, L4D2 默认 -20 把上半身压出视野)");
	g_cvRotYaw = CreateConVar("sm_legs_rot_yaw", "0.0", "偏航旋转(绕上轴)");
	g_cvRotRoll = CreateConVar("sm_legs_rot_roll", "0.0", "翻滚旋转(绕前轴)");
	// ★ v2.36 身体组隐藏（m_nBody 剔除上半身/手臂；腿实体已关阴影，无残缺阴影问题）
	g_cvBody = CreateConVar("sm_legs_body", "-1", "m_nBody 强制值: -1=自动(按模型隐藏上半身) 0=不设 其他=强制该值");
	g_cvHideUpper = CreateConVar("sm_legs_hide_upper", "1", "自动隐藏上半身/手臂(1开 0关，仅 sm_legs_body=-1 时生效)");
	
	AutoExecConfig(true, "csgo_legs");   // ★ v2.33 生成 cfg/sourcemod/csgo_legs.cfg 保存调参
	g_cvAnimTick = CreateConVar("sm_legs_animtick", "2", "动画同步间隔帧数(2=每2帧)");
	g_cvSDK = CreateConVar("sm_legs_sdk", "1", "使用 SDKCall 动画核心(1开/0关,0=退化仅设置序列)");
	g_cvCSAnim = CreateConVar("sm_legs_csanim", "0", "m_bClientSideAnimation: 0=服务器端权威(默认,我们每帧精确设cycle,站立冻结不闪) 1=客户端模拟(客户端自推进cycle→站着也闪) -1=不设置");
	g_cvAnimRate = CreateConVar("sm_legs_animrate", "1.0", "★ v2.18 腿动画自然节奏倍率(1.0=动画自身fps自然步频，调大加快调小放慢)");
	g_cvStride = CreateConVar("sm_legs_stride", "90.0", "一个完整步态循环(左右两步)对应位移units，调它让腿与脚步同步");
	g_cvCycleMode = CreateConVar("sm_legs_cyclemode", "0", "cycle模式: 0=仓库StudioFrameAdvance(默认) 1=位移积分覆盖");
	g_cvGroundSpeed = CreateConVar("sm_legs_groundspeed", "100.0", "自足驱动的序列地面速度(官方公式cycle+=(速度/地面速度)*dt)，调它让步态跟脚");
	g_cvTestSeq = CreateConVar("sm_legs_testseq", "0", "★ CT动画序列测试: 0=关闭(跟随玩家层) >0=锁定实体播放该全局序列(速度驱动cycle)\n已知序列: 24=move 26=move_knife 28=move_grenade 248=move_w(走) 249=move_r(跑) 8=rom(呼吸) 90=idle");
	g_cvHideBones = CreateConVar("sm_legs_hide_bones", "1", "★ v3.0 骨骼隐藏: 1=hook SetupBones 把腿实体 hand/arm/head 骨骼缩进身体(手/头消失) 0=关");
	// ★ v5.1 腿实体带枪开关：默认 0 不带枪（影子带枪功能保留，随时可开）
	g_cvWeapon = CreateConVar("sm_legs_weapon", "0", "腿实体带武器模型(影子带枪): 1=带 0=不带(默认)");
	
	// ★ v3.0 初始化 SetupBones detour（客户端骨骼矩阵 hook）
	InitBoneHide();
	// ★ v4.0 写初始控制文件（供注入 DLL 读取）
	WriteLegsCtrl();
	
	// ---- SDKCall 初始化（硬编码签名）----
	// void CBaseAnimating::ResetSequence(int nSequence)
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetSignature(SDKLibrary_Server, "\x55\x8B\xEC\xA1\x2A\x2A\x2A\x2A\x83\xEC\x08\x53\x56\x8B\xD9", 15);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	g_hResetSequence = EndPrepSDKCall();
	
	// int CBaseAnimatingOverlay::AllocateLayer(int iPriority)
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetSignature(SDKLibrary_Server, "\x55\x8B\xEC\x83\xEC\x14\x53\x8B\xC1", 9);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hAllocateLayer = EndPrepSDKCall();
	
	// void CBaseAnimating::StudioFrameAdvance()
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetSignature(SDKLibrary_Server, "\x55\x8B\xEC\x83\xE4\xC0\xA1\x2A\x2A\x2A\x2A\x83\xEC\x34\xF3\x0F\x10\x48\x10", 19);
	g_hStudioFrameAdvance = EndPrepSDKCall();
	
	g_bSDKReady = (g_hResetSequence != INVALID_HANDLE && g_hAllocateLayer != INVALID_HANDLE && g_hStudioFrameAdvance != INVALID_HANDLE);
	PrintToServer("[Legs] SDKCall 初始化: %s (Reset=%d Alloc=%d Frame=%d)", g_bSDKReady ? "成功" : "失败",
		g_hResetSequence != INVALID_HANDLE, g_hAllocateLayer != INVALID_HANDLE, g_hStudioFrameAdvance != INVALID_HANDLE);
	LogToFile("legs_debug.log", "[初始化] SDKCall: %s (Reset=%d Alloc=%d Frame=%d)", g_bSDKReady ? "成功" : "失败",
		g_hResetSequence != INVALID_HANDLE, g_hAllocateLayer != INVALID_HANDLE, g_hStudioFrameAdvance != INVALID_HANDLE);
	
	for (int i = 1; i <= MaxClients; i++)
		g_iLegsRef[i] = -1;
	
	// ★ v3.1 自动调试日志：每次启动游戏(插件加载)自动清除旧日志，重新记录本次测试
	// 文件: csgo/addons/sourcemod/logs/legs_debug.log
	//   - 大退游戏 = 插件重载 → 这里自动 DeleteFile → 重新测试从干净日志开始
	//   - 内容: 会话标记 + hook状态 + 骨骼解析 + SetupBones布局 + 改写生效 + 每5秒动画快照
	DeleteFile("legs_debug.log");
	LogToFile("legs_debug.log", "================ [Legs] 调试日志 新会话开始 ================");
	LogToFile("legs_debug.log", "说明: 本次启动已自动清除旧日志; 每次大退游戏重新测试会重新开始");
	LogToFile("legs_debug.log", "日志位置: 本文件(游戏目录下 legs_debug.log)");
	LogError("[Legs] 调试日志新会话开始 (legs_debug.log 已清除重建)");
	g_hDbgTimer = CreateTimer(5.0, Timer_AutoDbg, INVALID_HANDLE, TIMER_REPEAT);
}

public void OnMapStart()
{
	for (int i = 1; i <= MaxClients; i++)
		g_iLegsRef[i] = -1;
}

public void OnClientPutInServer(int client)
{
	g_bLegsEnabled[client] = true;
	g_iLegsRef[client] = -1;
	g_iWeaponRef[client] = -1;
	g_iWalkSeq[client] = -1;
}

public void OnClientDisconnect(int client)
{
	RemoveLegs(client);
	g_bLegsEnabled[client] = false;
}

public void OnPluginEnd()
{
	if (g_hDbgTimer != null)
	{
		KillTimer(g_hDbgTimer);
		g_hDbgTimer = null;
	}
	for (int i = 1; i <= MaxClients; i++)
		RemoveLegs(i);
	
	// ★ v3.0 关闭 SetupBones detour
	if (g_hSetupBonesDetour != null)
	{
		DHookDisableDetour(g_hSetupBonesDetour, true, SetupBonesPost);
		CloseHandle(g_hSetupBonesDetour);
		g_hSetupBonesDetour = null;
	}
	if (g_hBoneCache != null)
	{
		CloseHandle(g_hBoneCache);
		g_hBoneCache = null;
	}
}

// ============ 命令 ============

public Action Cmd_Legs(int client, int args)
{
	if (client < 1 || !IsClientInGame(client))
		return Plugin_Handled;
	
	g_bLegsEnabled[client] = !g_bLegsEnabled[client];
	
	if (g_bLegsEnabled[client])
	{
		RemoveLegs(client);
		CreateTimer(0.1, Timer_CreateLegs, GetClientUserId(client));
		PrintToChat(client, " \x04[Legs]\x01 已开启");
	}
	else
	{
		RemoveLegs(client);
		PrintToChat(client, " \x04[Legs]\x01 已关闭");
	}
	return Plugin_Handled;
}

// ============ 事件 ============

public void Event_PlayerSpawn(Event eEvent, const char[] szName, bool bDontBroadcast)
{
	int client = GetClientOfUserId(eEvent.GetInt("userid"));
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
		return;
	if (IsFakeClient(client))
		return;
	if (!IsPlayerAlive(client))
		return;
	
	RemoveLegs(client);
	
	if (g_bLegsEnabled[client])
		CreateTimer(0.3, Timer_CreateLegs, GetClientUserId(client));
}

public void Event_PlayerDeath(Event eEvent, const char[] szName, bool bDontBroadcast)
{
	int client = GetClientOfUserId(eEvent.GetInt("userid"));
	if (client < 1 || client > MaxClients)
		return;
	RemoveLegs(client);
}

public void Event_PlayerTeam(Event eEvent, const char[] szName, bool bDontBroadcast)
{
	int client = GetClientOfUserId(eEvent.GetInt("userid"));
	if (client < 1 || client > MaxClients)
		return;
	RemoveLegs(client);
}

// ============ 创建 ============

public Action Timer_CreateLegs(Handle timer, int iUserID)
{
	int client = GetClientOfUserId(iUserID);
	if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client))
		return Plugin_Stop;
	if (IsFakeClient(client) || !g_bLegsEnabled[client])
		return Plugin_Stop;
	
	CreateLegs(client);
	return Plugin_Stop;
}

// ★ v2.36: 计算腿实体 m_nBody（隐藏上半身/手臂，只显示腿）
//   模型 bodypart 分组（每组 1 个 model = 1 bit，bit=1(越界)即不渲染该组）：
// ★ v2.37: 运行时解析模型 bodypart，正确匹配每个探员/玩家模型（不再硬编码）
//   studiohdr v49: numbodyparts@0xCC, bodypartindex@0xD0; bodypart 记录 0x40/条
//   sznameindex 相对记录起点; 每组 1 个 model = 1 bit, bit=1(越界)即不渲染该组
//   策略：腿组关键词(lower/leg/pant/boot/feet/shoe/lwr)保留，其他全隐藏
//   无腿组 → 隐藏上半身/杂物组(head/upper/visor/glove/arm/helmet/...)，显示其余
//   结果按模型路径缓存(StringMap)，解析失败回退硬编码
stock int ParseModelBodyValue(const char[] sModel)
{
	if (g_hBodyCache == null)
		g_hBodyCache = new StringMap();
	
	int cached;
	if (g_hBodyCache.GetValue(sModel, cached))
		return cached;
	
	int result = -1;
	// ★ 必须 use_valve_fs=true + "GAME"：模型在 VPK 里，走 Valve 文件系统才能读
	File hFile = OpenFile(sModel, "rb", true, "GAME");
	if (hFile != INVALID_HANDLE)
	{
		FileSeek(hFile, 0xCC, SEEK_SET);
		int numBody, bpIdx;
		hFile.ReadInt32(numBody);
		hFile.ReadInt32(bpIdx);
		
		if (numBody >= 1 && numBody <= 20 && bpIdx > 0x100 && bpIdx < 0x400000)
		{
			int lowerMask = 0;
			int fullMask = 0;
			for (int i = 0; i < numBody; i++)
			{
				int bit = 1 << i;
				fullMask |= bit;
				
				int rec = bpIdx + i * 0x40;
				FileSeek(hFile, rec, SEEK_SET);
				int sz;
				hFile.ReadInt32(sz);
				if (sz < 0 || sz > 0x10000)
					continue;
				
				FileSeek(hFile, rec + sz, SEEK_SET);
				char name[96];
				hFile.ReadString(name, sizeof(name));
				
				if (StrContains(name, "lower") != -1 || StrContains(name, "leg") != -1 ||
				    StrContains(name, "pant") != -1 || StrContains(name, "boot") != -1 ||
				    StrContains(name, "feet") != -1 || StrContains(name, "shoe") != -1 ||
				    StrContains(name, "lwr") != -1)
					lowerMask |= bit;
			}
			
			if (lowerMask != 0)
			{
				// 全隐藏，只留腿组
				result = fullMask & ~lowerMask;
			}
			else
			{
				// 无腿组关键词：只隐藏明确上半身/杂物组，显示其余（如潜水服身体）
				result = 0;
				for (int i = 0; i < numBody; i++)
				{
					int rec = bpIdx + i * 0x40;
					FileSeek(hFile, rec, SEEK_SET);
					int sz;
					hFile.ReadInt32(sz);
					if (sz < 0 || sz > 0x10000) continue;
					FileSeek(hFile, rec + sz, SEEK_SET);
					char name[96];
					hFile.ReadString(name, sizeof(name));
					if (StrContains(name, "head") != -1 || StrContains(name, "upper") != -1 ||
					    StrContains(name, "visor") != -1 || StrContains(name, "glove") != -1 ||
					    StrContains(name, "arm") != -1 || StrContains(name, "helmet") != -1 ||
					    StrContains(name, "balaclava") != -1 || StrContains(name, "hat") != -1 ||
					    StrContains(name, "radio") != -1 || StrContains(name, "tank") != -1 ||
					    StrContains(name, "breather") != -1 || StrContains(name, "dualtank") != -1 ||
					    StrContains(name, "exojump") != -1 || StrContains(name, "vest") != -1)
						result |= (1 << i);
				}
			}
		}
		else
		{
			// 头部字段异常，走 fallback
		}
		CloseHandle(hFile);
	}
	
	if (result < 0)
	{
		// 解析失败回退硬编码
		if (StrContains(sModel, "custom_player") != -1)
			result = 30;
		else if (StrContains(sModel, "ctm_gign") != -1 ||
		         StrContains(sModel, "ctm_gsg9") != -1 ||
		         StrContains(sModel, "ctm_st6") != -1 ||
		         StrContains(sModel, "ctm_swat") != -1 ||
		         StrContains(sModel, "ctm_sas") != -1)
			result = 11;
		else
			result = 3;
	}
	
	g_hBodyCache.SetValue(sModel, result, true);
	return result;
}

stock int GetLegsBodyValue(const char[] sModel)
{
	// 手动强制值优先
	if (g_cvBody != null && g_cvBody.IntValue >= 0)
		return g_cvBody.IntValue;
	// 关闭自动隐藏
	if (g_cvHideUpper == null || g_cvHideUpper.IntValue == 0)
		return 0;
	// ★ v2.37 运行时解析模型 bodypart，正确匹配每个模型
	return ParseModelBodyValue(sModel);
}

void CreateLegs(int client)
{
	RemoveLegs(client);
	g_flWalkDist[client] = 0.0;  // 重置步态相位
	g_iWalkSeq[client] = -1;     // 重置移动序列缓存
	
	char sModel[PLATFORM_MAX_PATH];
	GetEntPropString(client, Prop_Data, "m_ModelName", sModel, sizeof(sModel));
	if (sModel[0] == '\0')
		return;
	
	PrecacheModel(sModel, true);
	
	// ★ v2.29 移除 SetEntityModel 强制重设：
	//   玩家模型本身就是 custom_player → 正常重生时 CCSPlayer::SetModel 自动设
	//   m_bUseNewAnimstate=true（层6 自动更新）。强制重设会在重生瞬间破坏动画状态机
	//   → 「选择人物后有概率触发闪烁、触发后持续」的根因
	//   若 overlay 偶尔读不到，有缓存序列 + 位移积分兜底，不影响播放
	
	int iEntity = CreateEntityByName("monster_generic");
	if (iEntity < 0)
	{
		PrintToServer("[Legs] monster_generic 创建失败");
		LogToFile("legs_debug.log", "[实体] 错误: monster_generic 创建失败 client=%d", client);
		return;
	}
	
	float fPos[3], fAng[3];
	GetClientAbsOrigin(client, fPos);
	GetClientEyeAngles(client, fAng);
	
	DispatchKeyValueVector(iEntity, "origin", fPos);
	DispatchKeyValueVector(iEntity, "angles", fAng);
	DispatchKeyValue(iEntity, "model", sModel);
	DispatchKeyValue(iEntity, "spawnflags", "5000");
	
	DispatchSpawn(iEntity);
	ActivateEntity(iEntity);
	
	SetEntityMoveType(iEntity, MOVETYPE_NONE);
	AcceptEntityInput(iEntity, "DisableShadow");
	
	// ★ v2.36 删影子：m_fEffects 加 EF_NOSHADOW|EF_NORECEIVESHADOW 彻底关阴影
	//   （配合身体组隐藏：隐藏网格会让阴影残缺，干脆不要腿实体阴影）
	// ★ v5.19 加 EF_NOSHADOWDEPTH|EF_NOCSM：关掉 CSM 级联阴影（L4D 腿部脚本同款，纯服务端方案）
	int iFX = GetEntProp(iEntity, Prop_Send, "m_fEffects");
	iFX |= EF_NOSHADOW | EF_NORECEIVESHADOW | EF_NOSHADOWDEPTH | EF_NOCSM | EF_SHADOWDEPTH_NOCACHE;
	SetEntProp(iEntity, Prop_Send, "m_fEffects", iFX);
	
	// ★ v5.2 延迟一帧二次屏蔽阴影（实体 spawn 时 m_fEffects 可能被引擎重置）
	RequestFrame(ShadowOffFrame, iEntity);
	
	// m_bClientSideAnimation：默认不强制（保持引擎默认，通常=1 客户端模拟）
	// sm_legs_csanim 0/1 可强制切换（诊断用）
	if (g_cvCSAnim != null && g_cvCSAnim.IntValue >= 0)
	{
		int iCSA = GetEntProp(iEntity, Prop_Send, "m_bClientSideAnimation");
		SetEntProp(iEntity, Prop_Send, "m_bClientSideAnimation", g_cvCSAnim.IntValue);
		PrintToServer("[Legs] ent=%d m_bClientSideAnimation 默认=%d -> 强制%d", iEntity, iCSA, g_cvCSAnim.IntValue);
	}
	else
	{
		PrintToServer("[Legs] ent=%d m_bClientSideAnimation 保持默认=%d", iEntity, GetEntProp(iEntity, Prop_Send, "m_bClientSideAnimation"));
	}
	
	int iFlags = GetEntProp(iEntity, Prop_Data, "m_iEFlags");
	iFlags |= EFL_DONTBLOCKLOS;
	SetEntProp(iEntity, Prop_Data, "m_iEFlags", iFlags);
	
	// 照仓库 CSGO_Aimbot 克隆：同步皮肤 + 设置 owner（SetupAnimations 靠它取玩家）
	SetEntProp(iEntity, Prop_Send, "m_nSkin", GetEntProp(client, Prop_Send, "m_nSkin"));
	
	// ★ v3.1 已移除 m_nBody 身体组隐藏（v2.36/v2.37 机制）：
	//   手/头隐藏改由 v3.0 骨骼矩阵方案接管（SetupBones hook 把 hand/arm/head 骨骼缩进身体）
	//   上半身靠位置机制(off_z/rot_pitch)压出视野。
	//   如需恢复 m_nBody：取消下面注释（sm_legs_body/sm_legs_hide_upper ConVar 仍保留）
	/*
	int iBody = GetLegsBodyValue(sModel);
	if (iBody != 0)
	{
		SetEntProp(iEntity, Prop_Send, "m_nBody", iBody);
		PrintToServer("[Legs] ent=%d m_nBody=%d (隐藏上半身/手臂)", iEntity, iBody);
	}
	*/
	
	SetEntPropEnt(iEntity, Prop_Data, "m_hOwnerEntity", client);
	
	// 照仓库：延迟一帧 SetupLayers + SetupAnimations（等实体完全生成）
	if (g_bSDKReady && g_cvSDK != null && g_cvSDK.IntValue == 1)
	{
		RequestFrame(SetupLayersFrame, iEntity);
		RequestFrame(SetupAnimationsFrame, iEntity);
	}
	else
	{
		// 无 SDK 降级：仅设序列
		SetEntProp(iEntity, Prop_Data, "m_nSequence", GetEntProp(client, Prop_Send, "m_nSequence"));
	}
	
	g_iLegsRef[client] = EntIndexToEntRef(iEntity);
	g_iWeaponRef[client] = -1;
	g_iLegsOwner[iEntity] = GetClientUserId(client);
	
	// ★ v3.0 骨骼隐藏：解析模型 hand/arm/head 骨骼索引（SetupBones hook 用它缩进身体）
	ParseBonesForClient(client, sModel);
	g_iBoneHideEnt[iEntity] = client;
	
	// ★ v4.0 写控制文件通知注入 DLL（腿实体+骨骼索引）
	WriteLegsCtrl();
	
	SDKHook(iEntity, SDKHook_SetTransmit, Hook_SetTransmit);
	SDKHook(client, SDKHook_PostThinkPost, Hook_PostThinkPost);
	SDKHook(client, SDKHook_WeaponSwitchPost, Hook_WeaponSwitchPost);
	
	// ★ v2.31 武器模型绑定（影子带枪）：延迟一帧等实体生成
	RequestFrame(AttachWeaponFrame, iEntity);
	
	// ★ 模型加载后延迟读取一次移动序列（缓存，之后稳定使用）
	CreateTimer(0.5, Timer_ReadModelSeq, GetClientUserId(client));
	
	PrintToServer("[Legs] 腿实体创建成功! ent=%d model=%s sdk=%d", iEntity, sModel, g_bSDKReady);
	LogToFile("legs_debug.log", "[实体] 腿实体创建成功! ent=%d client=%d model=%s sdk=%d", iEntity, client, sModel, g_bSDKReady);
}

// ★ v5.2 延迟一帧二次屏蔽腿实体阴影（只影响我们创建的腿实体，绝不碰原生玩家模型）
public void ShadowOffFrame(int iEntity)
{
	if (!IsValidEntity(iEntity))
		return;
	
	AcceptEntityInput(iEntity, "DisableShadow");
	int iFX = GetEntProp(iEntity, Prop_Send, "m_fEffects");
	iFX |= EF_NOSHADOW | EF_NORECEIVESHADOW | EF_NOSHADOWDEPTH | EF_NOCSM | EF_SHADOWDEPTH_NOCACHE;
	SetEntProp(iEntity, Prop_Send, "m_fEffects", iFX);
}

// ============ 武器绑定（v2.31，照 PlayerClone 复制武器 world model）============
// 把玩家活动武器的 world model 创建为 prop_dynamic，BONEMERGE 绑到实体右手骨
// → 实体影子带枪，跟随动画
public void AttachWeaponFrame(int iEntity)
{
	if (!IsValidEntity(iEntity))
		return;
	
	int client = GetEntPropEnt(iEntity, Prop_Data, "m_hOwnerEntity");
	if (client < 1 || !IsClientInGame(client))
		return;
	
	AttachWeapon(client, iEntity);
}

// ★ v2.31 武器绑定：把玩家活动武器的 world model 创建为 prop_dynamic，BONEMERGE 绑到实体右手骨
// → 实体影子带枪，跟随动画
void AttachWeapon(int client, int iEntity)
{
	// 清理旧武器
	if (IsValidEntRef(g_iWeaponRef[client]))
	{
		int old = EntRefToEntIndex(g_iWeaponRef[client]);
		if (old > 0 && IsValidEntity(old))
			RemoveEntity(old);
	}
	g_iWeaponRef[client] = -1;
	
	// ★ v5.1 默认不带枪（sm_legs_weapon 0）：清理完旧武器直接返回
	if (g_cvWeapon == null || g_cvWeapon.IntValue == 0)
		return;
	
	if (client < 1 || !IsClientInGame(client))
		return;
	if (iEntity <= 0 || !IsValidEntity(iEntity))
		return;
	
	// 读玩家活动武器 world model（modelprecache 字符串表）
	int iWeapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
	if (iWeapon <= 0 || !IsValidEntity(iWeapon))
		return;
	
	int iWorldModel = GetEntProp(iWeapon, Prop_Send, "m_iWorldModelIndex");
	if (iWorldModel <= 0)
		return;
	
	char sModel[PLATFORM_MAX_PATH];
	ReadStringTable(FindStringTable("modelprecache"), iWorldModel, sModel, sizeof(sModel));
	if (sModel[0] == '\0')
		return;
	
	PrecacheModel(sModel, true);
	
	int item = CreateEntityByName("prop_dynamic");
	if (item < 0)
		return;
	
	DispatchKeyValue(item, "model", sModel);
	DispatchSpawn(item);
	ActivateEntity(item);
	
	SetEntProp(item, Prop_Send, "m_nSkin", GetEntProp(client, Prop_Send, "m_nSkin"));
	SetEntPropEnt(item, Prop_Data, "m_hOwnerEntity", iEntity);
	SetEntProp(item, Prop_Send, "m_fEffects", EF_BONEMERGE | EF_PARENT_ANIMATES);
	
	SetEntPropEnt(iEntity, Prop_Data, "m_hEffectEntity", item);
	
	SetVariantString("!activator");
	AcceptEntityInput(item, "SetParent", iEntity);
	
	// 固定绑右手骨（模型没有左手，左右手支持无效）
	SetVariantString("weapon_hand_r");
	AcceptEntityInput(item, "SetParentAttachmentMaintainOffset");
	
	g_iWeaponRef[client] = EntIndexToEntRef(item);
	PrintToServer("[Legs] 武器模型绑定: %s -> ent=%d (weapon_hand_r)", sModel, item);
}

// 切枪时更新武器模型
public void Hook_WeaponSwitchPost(int client, int iWeapon)
{
	if (IsFakeClient(client))
		return;
	
	int iEntity = EntRefToEntIndex(g_iLegsRef[client]);
	if (iEntity <= 0 || !IsValidEntity(iEntity))
		return;
	
	AttachWeapon(client, iEntity);
}

// 模型加载后读一次移动层序列并缓存（用户要求：模型选好/加载好就能读出动画数据）
public Action Timer_ReadModelSeq(Handle timer, int iUserID)
{
	int client = GetClientOfUserId(iUserID);
	if (client < 1 || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Stop;
	
	float flCycle, flWeight;
	int iSeq = GetMoveLayer(client, flCycle, flWeight);
	if (iSeq > 0)
	{
		g_iWalkSeq[client] = iSeq;
		PrintToServer("[Legs] 模型动画已读取: 移动序列=%d weight=%.2f (缓存)", iSeq, flWeight);
	}
	else
	{
		// 动画系统可能还没初始化，重试
		CreateTimer(1.0, Timer_ReadModelSeq, iUserID);
	}
	return Plugin_Stop;
}

void RemoveLegs(int client)
{
	if (client < 1 || client > MaxClients)
		return;
	
	if (IsValidEntRef(g_iLegsRef[client]))
	{
		int iEntity = EntRefToEntIndex(g_iLegsRef[client]);
		SDKUnhook(iEntity, SDKHook_SetTransmit, Hook_SetTransmit);
		RemoveEntity(iEntity);
		g_iBoneHideEnt[iEntity] = 0;   // ★ v3.0 清除骨骼隐藏目标
	}
	g_iLegsRef[client] = -1;
	g_iHideBoneCount[client] = 0;     // ★ v3.0 清除骨骼索引
	
	// 删除武器 prop（v2.31）
	if (IsValidEntRef(g_iWeaponRef[client]))
	{
		int iWeaponEnt = EntRefToEntIndex(g_iWeaponRef[client]);
		if (iWeaponEnt > 0 && IsValidEntity(iWeaponEnt))
			RemoveEntity(iWeaponEnt);
	}
	g_iWeaponRef[client] = -1;
	
	SDKUnhook(client, SDKHook_PostThinkPost, Hook_PostThinkPost);
	SDKUnhook(client, SDKHook_WeaponSwitchPost, Hook_WeaponSwitchPost);
	
	// ★ v4.0 写控制文件通知注入 DLL（移除腿实体）
	WriteLegsCtrl();
}

// ============ 动画同步核心（PlayerClone 方式）============

Address GetOverlay(int iEntity)
{
	// 注意：FindDataMapInfo 的【返回值】才是偏移量，第三个参数是字段类型！
	// ★ v2.11: FindDataMapInfo 会间歇失败（重生瞬间）→ 缓存上次成功偏移复用
	// ★ v2.24 关键修复：GetEntityAddress 返回高位地址(>2GB)，view_as<int> 会变负数！
	//   ⚠️ 之前用 view_as<int>(GetEntityAddress()) <= 0 判断失败 → 高位地址被误杀 → overlay 恒 NULL！
	//   必须用 Address_Null 比较（不转 signed int）
	PropFieldType iType;
	int iFindRet = FindDataMapInfo(iEntity, "m_AnimOverlay", iType);
	int iOff = iFindRet;
	if (iOff > 0)
		g_iOverlayOffset = iOff;   // 成功：更新缓存
	else if (g_iOverlayOffset > 0)
		iOff = g_iOverlayOffset;   // 失败：用缓存
	else
		iOff = 0x4D4;              // 最终兜底：AllocateLayer 逆向确认偏移
	
	Address iBase = GetEntityAddress(iEntity);
	if (iBase == Address_Null)
	{
		if (!g_bOverlayDiagLogged)
		{
			LogToFile("legs_debug.log", "[诊断] GetOverlay: GetEntityAddress 返回 NULL");
			g_bOverlayDiagLogged = true;
		}
		return Address_Null;
	}
	
	int iOverlayPtr = LoadFromAddress(iBase + view_as<Address>(iOff), NumberType_Int32);
	if (iOverlayPtr <= 0)
	{
		if (!g_bOverlayDiagLogged)
		{
			LogToFile("legs_debug.log", "[诊断] GetOverlay: FindRet=%d 缓存偏移=0x%X 实际偏移=0x%X 读overlay指针=%d",
				iFindRet, g_iOverlayOffset, iOff, iOverlayPtr);
			g_bOverlayDiagLogged = true;
		}
		return Address_Null;
	}
	
	return view_as<Address>(iOverlayPtr);
}

// 与 GetMoveLayer 同逻辑（诊断用）：直接读 MOVEMENT_MOVE 固定槽位(索引6)
int GetActiveOverlaySequence(int client, float &flCycle, float &flWeight)
{
	Address overlay = GetOverlay(client);
	if (overlay == Address_Null)
		return -1;
	
	// ★ v2.13: 固定槽位索引6 = MOVEMENT_MOVE（日志证实，见 GetMoveLayer 注释）
	Address layer = overlay + view_as<Address>(6 * CAnimationLayer_Size);
	int seq = LoadFromAddress(layer + view_as<Address>(LAYER_SEQ), NumberType_Int32);
	float w = view_as<float>(LoadFromAddress(layer + view_as<Address>(LAYER_WEIGHT), NumberType_Int32));
	float c = view_as<float>(LoadFromAddress(layer + view_as<Address>(LAYER_CYCLE), NumberType_Int32));
	
	if (seq > 0 && w > 0.5)
	{
		flCycle = c;
		flWeight = w;
		return seq;
	}
	return -1;
}

// 照仓库：延迟帧 SetupLayers（分配动画层）
public void SetupLayersFrame(int iEntity)
{
	if (!IsValidEntity(iEntity))
		return;
	
	PropFieldType iType;
	if (FindDataMapInfo(iEntity, "m_AnimOverlay", iType) > 0)
	{
		for (int i = 0; i <= NUM_LAYERS; i++)
			SDKCall(g_hAllocateLayer, iEntity, 0);
	}
	else
	{
		PrintToServer("[Legs] monster_generic 无 m_AnimOverlay 字段，跳过动画层分配");
	}
}

// 照仓库：延迟帧 SetupAnimations（初始同步一次动画）
public void SetupAnimationsFrame(int iEntity)
{
	if (!IsValidEntity(iEntity))
		return;
	
	int client = GetEntPropEnt(iEntity, Prop_Data, "m_hOwnerEntity");
	if (client < 1 || !IsClientInGame(client) || IsFakeClient(client))
		return;
	
	SyncAnimation(client, iEntity);
}

// 按 m_nOrder 顺序映射找语义层（GetAnimOverlay(index, false) 的逻辑）
// 语义层号(animstate_layer_t)：0=AIMMATRIX, 6=MOVEMENT_MOVE, 8=WHOLE_BODY...
Address GetAnimOverlayByOrder(int client, int nOrder)
{
	Address overlay = GetOverlay(client);
	if (overlay == Address_Null)
		return Address_Null;
	
	for (int i = 0; i < 15; i++)  // 最大 15 层（AllocateLayer 确认 0xF）
	{
		Address layer = overlay + view_as<Address>(i * CAnimationLayer_Size);
		int order = LoadFromAddress(layer + view_as<Address>(LAYER_ORDER), NumberType_Int32);
		if (order == nOrder)
			return layer;
	}
	return Address_Null;
}

// 读玩家基础层(o=0)序列（v2.15: 静止 idle 用它，替代硬编码 90）
//   日志证实：overlay[0] 恒为基础层，静止时 s=90(站立)/移动时 s=172，w=1.00 恒
int GetBaseLayerSeq(int client)
{
	Address overlay = GetOverlay(client);
	if (overlay == Address_Null)
		return -1;
	
	Address layer = overlay;   // 索引 0 = 基础层
	int seq = LoadFromAddress(layer + view_as<Address>(LAYER_SEQ), NumberType_Int32);
	float w = view_as<float>(LoadFromAddress(layer + view_as<Address>(LAYER_WEIGHT), NumberType_Int32));
	if (seq > 0 && w > 0.5)
		return seq;
	return -1;
}

// 只读 MOVEMENT_MOVE 移动层
// ★ v2.13 关键修复：直接读 overlay 数组【固定槽位索引 6】= MOVEMENT_MOVE
//   日志证实：所有快照里索引[6] 的 seq 恒为移动序列(26/28)，索引[11]=ALIVELOOP，索引[12]=LEAN
//   ⚠️ 之前按 order 5/6 遍历是错的！order 只是 ApplyLayerOrderPreset 的显示优先级
//     （Default=6/WeaponPost=5），order=5 的层可能是武器/杂层(s=22/59)
//     → 误选导致 seq 乱切闪烁 / v2.9"倒地"(s=59) 的根源
	// ★ v2.28 阈值回 0.5：v2.16 降到 0.01 是错的！静止时层6 weight 残留(0.2)会被误判为移动 → 站着播走路动画 → 闪烁
	int GetMoveLayer(int client, float &flCycle, float &flWeight)
	{
		Address overlay = GetOverlay(client);
		if (overlay == Address_Null)
			return -1;
		
		Address layer = overlay + view_as<Address>(6 * CAnimationLayer_Size);
		int seq = LoadFromAddress(layer + view_as<Address>(LAYER_SEQ), NumberType_Int32);
		float w = view_as<float>(LoadFromAddress(layer + view_as<Address>(LAYER_WEIGHT), NumberType_Int32));
		float c = view_as<float>(LoadFromAddress(layer + view_as<Address>(LAYER_CYCLE), NumberType_Int32));
		
		if (seq > 0 && w > 0.5)
		{
			flCycle = c;
			flWeight = w;
			return seq;
		}
		return -1;
	}

void SyncAnimation(int client, int iEntity)
{
	// ★★ v2.2 双模式（基于源码：m_bUseNewAnimstate = 模型名含 custom_player）：
	//   custom_player 模型 → 服务器端动画状态机每帧更新层6 → 玩家驱动（直接同步层6 seq+cycle）
	//   其他模型 → 自足驱动（缓存序列 + 官方位移积分公式）
	float vel[3];
	GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
	float flSpeed = SquareRoot(vel[0] * vel[0] + vel[1] * vel[1]);
	
	// ★★ v2.14 CT 动画序列测试模式：sm_legs_testseq > 0 时
	//    锁定实体播放指定全局序列（速度驱动 cycle），逐个实测动画对应关系
	if (g_cvTestSeq != null && g_cvTestSeq.IntValue > 0)
	{
		int iSeq = g_cvTestSeq.IntValue;
		int iCurSeq = GetEntProp(iEntity, Prop_Send, "m_nSequence");
		if (iSeq != iCurSeq)
		{
			if (g_bSDKReady)
				SDKCall(g_hResetSequence, iEntity, iSeq);
			else
				SetEntProp(iEntity, Prop_Data, "m_nSequence", iSeq);
			SetEntProp(iEntity, Prop_Send, "m_nSequence", iSeq);
		}
		// cycle：位移积分（跑动时动画走起来）
		float flGS = (g_cvGroundSpeed != null) ? g_cvGroundSpeed.FloatValue : 100.0;
		if (flGS < 1.0) flGS = 1.0;
		g_flWalkDist[client] += flSpeed / 64.0;
		float flCycle = g_flWalkDist[client] / flGS;
		flCycle -= float(RoundToFloor(flCycle));
		if (HasEntProp(iEntity, Prop_Send, "m_flCycle"))
			SetEntPropFloat(iEntity, Prop_Send, "m_flCycle", flCycle);
		SyncPose(client, iEntity);
		return;
	}
	
	// ★★ v2.30 完全复刻 PlayerClone 的「magic maker」同步机制：
	//   ① 实体主序列 = 玩家主序列
	//   ② ★ 复制玩家【整个 overlay 12 层】到实体（逐字段，偏移0x10=m_flPlaybackRate 设 0）
	//   ③ 复制 24 个 pose
	//   → 实体获得与玩家完全一致的动画层数据，客户端直接渲染这些层
	//   → 与玩家第三人称一模一样，天然不闪（数据来自引擎、连续，无需自己推 cycle）
	//   → 不需要 GetMoveLayer/位移积分/csanim/StudioFrameAdvance 折腾
	// 参考：Pelipoika/The-unfinished-and-abandoned → CSGO_PlayerClone.sp SetupAnimations
	//   （每帧调用 = Aimbot 的 Clone_SetupAnimations 每帧同步）
	
	// ① 实体主序列 = 玩家主序列（PlayerClone 每次都 ResetSequence）
	if (g_bSDKReady)
		SDKCall(g_hResetSequence, iEntity, GetEntProp(client, Prop_Send, "m_nSequence"));
	else
		SetEntProp(iEntity, Prop_Data, "m_nSequence", GetEntProp(client, Prop_Send, "m_nSequence"));
	
	// ② 复制玩家整个 overlay 到实体（magic maker）
	Address overlayP = GetOverlay(client);
	Address overlay  = GetOverlay(iEntity);
	if (overlayP != Address_Null && overlay != Address_Null)
	{
		for (int i = 0; i <= NUM_LAYERS; i++)
		{
			Address layerP = overlayP + view_as<Address>(i * CAnimationLayer_Size);
			Address layer  = overlay  + view_as<Address>(i * CAnimationLayer_Size);
			
			for (int x = 0; x < (CAnimationLayer_Size / 4); x++)
			{
				if (x == 4)
				{
					// 偏移 0x10 = m_flPlaybackRate → 设 0（层不自己推进 cycle，由复制数据驱动）
					StoreToAddress(layer + view_as<Address>(x * 4), 0, NumberType_Int32);
				}
				else
				{
					any iData = LoadFromAddress(layerP + view_as<Address>(x * 4), NumberType_Int32);
					StoreToAddress(layer + view_as<Address>(x * 4), iData, NumberType_Int32);
				}
			}
		}
	}
	
	// ③ 复制 24 个 pose
	SyncPose(client, iEntity);
}

void SyncPose(int client, int iEntity)
{
	if (HasEntProp(iEntity, Prop_Send, "m_flPoseParameter"))
	{
		for (int i = 0; i < 24; i++)
			SetEntPropFloat(iEntity, Prop_Send, "m_flPoseParameter", GetEntPropFloat(client, Prop_Send, "m_flPoseParameter", i), i);
	}
}

// ============ 诊断 ============

public Action Cmd_LegsDbg(int client, int args)
{
	if (client < 1 || !IsClientInGame(client))
		return Plugin_Handled;
	
	// ★ v4.0 扩展状态（csgo_legs.ext.dll 由 SourceMod 自动加载）
	char extState[512];
	ReadLegsExtState(extState, sizeof(extState));
	PrintToServer("[Legs] DBG 扩展: %s", extState);
	
	int iEntity = EntRefToEntIndex(g_iLegsRef[client]);
	if (iEntity <= 0 || !IsValidEntity(iEntity))
	{
		PrintToServer("[Legs] DBG: 无腿实体，先 sm_legs");
		return Plugin_Handled;
	}
	
	int iSeq = GetEntProp(client, Prop_Send, "m_nSequence");
	float flCycle = GetEntPropFloat(client, Prop_Send, "m_flCycle");
	float flActiveCycle, flActiveWeight;
	int iActiveSeq = GetActiveOverlaySequence(client, flActiveCycle, flActiveWeight);
	
	PrintToServer("[Legs] DBG 玩家: seq=%d cycle=%.3f", iSeq, flCycle);
	PrintToServer("[Legs] DBG active层: seq=%d weight=%.3f cycle=%.3f", iActiveSeq, flActiveWeight, flActiveCycle);
	PrintToServer("[Legs] DBG 实体: seq=%d cycle=%.3f csanim=%d",
		GetEntProp(iEntity, Prop_Send, "m_nSequence"),
		GetEntPropFloat(iEntity, Prop_Send, "m_flCycle"),
		GetEntProp(iEntity, Prop_Send, "m_bClientSideAnimation"));
	
	// 玩家 overlay 前 4 层详情（判断服务器端是否有动画数据）
	Address overlay = GetOverlay(client);
	if (overlay != Address_Null)
	{
		for (int i = 0; i < 4; i++)
		{
			Address layer = overlay + view_as<Address>(i * CAnimationLayer_Size);
			int seq = LoadFromAddress(layer + view_as<Address>(LAYER_SEQ), NumberType_Int32);
			float w = view_as<float>(LoadFromAddress(layer + view_as<Address>(LAYER_WEIGHT), NumberType_Int32));
			float c = view_as<float>(LoadFromAddress(layer + view_as<Address>(LAYER_CYCLE), NumberType_Int32));
			float rate = view_as<float>(LoadFromAddress(layer + view_as<Address>(LAYER_RATE), NumberType_Int32));
			PrintToServer("[Legs] DBG layer%d: seq=%d weight=%.2f cycle=%.2f rate=%.2f", i, seq, w, c, rate);
		}
	}
	else
	{
		PrintToServer("[Legs] DBG: 玩家 overlay 为 NULL!");
	}
	
	PrintToServer("[Legs] DBG: 走路时再执行一次本命令对比 seq/weight/cycle 是否变化");
	return Plugin_Handled;
}

// ============ 自动诊断（写入文件，无需命令，不刷控制台）============
// 日志位置: csgo/addons/sourcemod/logs/legs_debug.log

public Action Timer_AutoDbg(Handle timer, any data)
{
	// ★ v4.1 周期重写控制文件（确保 DLL 始终拿到最新腿实体列表，防 RemoveLegs 清空后不再更新）
	WriteLegsCtrl();
	
	// 每 5 秒打印所有玩家第三人称动画快照（模型/主序列/所有overlay层/实体/关键pose）
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
			continue;
		
		// 模型名（判断是否 custom_player → m_bUseNewAnimstate）
		char model[PLATFORM_MAX_PATH];
		GetEntPropString(client, Prop_Data, "m_ModelName", model, sizeof(model));
		
		// 水平速度
		float vel[3];
		GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
		float speed = SquareRoot(vel[0] * vel[0] + vel[1] * vel[1]);
		
		// 玩家主序列
		int iSeq = GetEntProp(client, Prop_Send, "m_nSequence");
		float flCycle = GetEntPropFloat(client, Prop_Send, "m_flCycle");
		
		// 所有 overlay 层快照（第三人称实际播放的序列）
		Address overlay = GetOverlay(client);
		char layerInfo[1024];
		layerInfo[0] = '\0';
		if (overlay != Address_Null)
		{
			for (int i = 0; i < 15; i++)
			{
				Address layer = overlay + view_as<Address>(i * CAnimationLayer_Size);
				int order = LoadFromAddress(layer + view_as<Address>(LAYER_ORDER), NumberType_Int32);
				int seq = LoadFromAddress(layer + view_as<Address>(LAYER_SEQ), NumberType_Int32);
				float w = view_as<float>(LoadFromAddress(layer + view_as<Address>(LAYER_WEIGHT), NumberType_Int32));
				float c = view_as<float>(LoadFromAddress(layer + view_as<Address>(LAYER_CYCLE), NumberType_Int32));
				
				if (seq > 0 || w > 0.01)
				{
					char tmp[96];
					Format(tmp, sizeof(tmp), " [%d]o=%d s=%d w=%.2f c=%.2f", i, order, seq, w, c);
					StrCat(layerInfo, sizeof(layerInfo), tmp);
				}
			}
		}
		else
		{
			StrCat(layerInfo, sizeof(layerInfo), " overlay=NULL");
		}
		
		// 实体当前状态
		int iEntity = EntRefToEntIndex(g_iLegsRef[client]);
		int iEntSeq = -1;
		float flEntCycle = -1.0;
		int iCSA = -1;
		float flEntRate = -1.0;
		if (iEntity > 0 && IsValidEntity(iEntity))
		{
			iEntSeq = GetEntProp(iEntity, Prop_Send, "m_nSequence");
			flEntCycle = GetEntPropFloat(iEntity, Prop_Send, "m_flCycle");
			iCSA = GetEntProp(iEntity, Prop_Send, "m_bClientSideAnimation");
			flEntRate = GetEntPropFloat(iEntity, Prop_Send, "m_flPlaybackRate");
		}
		
		LogToFile("legs_debug.log",
			"[%N] 模型=%s 速=%.0f | 玩家主seq=%d cyc=%.3f | 实体seq=%d cyc=%.3f csanim=%d rate=%.1f 缓存seq=%d | 位移=%.0f",
			client, model, speed, iSeq, flCycle, iEntSeq, flEntCycle, iCSA, flEntRate, g_iWalkSeq[client], g_flWalkDist[client]);
		LogToFile("legs_debug.log", "[%N] 层:%s", client, layerInfo);
		
		// ★ 位置诊断（卡原地排查）：玩家 origin vs 实体 origin
		if (iEntity > 0 && IsValidEntity(iEntity))
		{
			float fPO[3], fEO[3];
			GetClientAbsOrigin(client, fPO);
			GetEntPropVector(iEntity, Prop_Data, "m_vecOrigin", fEO);
			LogToFile("legs_debug.log",
				"[位置] 玩家=(%.1f,%.1f,%.1f) 实体origin=(%.1f,%.1f,%.1f) 位移=%.0f",
				fPO[0], fPO[1], fPO[2], fEO[0], fEO[1], fEO[2], g_flWalkDist[client]);
		}
		
		// 关键 pose（第三人称走路驱动参数）
		if (HasEntProp(client, Prop_Send, "m_flPoseParameter"))
		{
			LogToFile("legs_debug.log",
				"[%N] pose: leanYaw=%.2f SPEED=%.2f MOVE_YAW=%.2f RUN=%.2f MBW=%.2f MBR=%.2f",
				client,
				GetEntPropFloat(client, Prop_Send, "m_flPoseParameter", 0),
				GetEntPropFloat(client, Prop_Send, "m_flPoseParameter", 1),
				GetEntPropFloat(client, Prop_Send, "m_flPoseParameter", 4),
				GetEntPropFloat(client, Prop_Send, "m_flPoseParameter", 5),
				GetEntPropFloat(client, Prop_Send, "m_flPoseParameter", 17),
				GetEntPropFloat(client, Prop_Send, "m_flPoseParameter", 18));
		}
	}
	return Plugin_Continue;
}

// ============ 每帧 ============

public void Hook_PostThinkPost(int client)
{
	if (IsFakeClient(client))
		return;
	if (!IsPlayerAlive(client))
		return;
	
	int iEntity = EntRefToEntIndex(g_iLegsRef[client]);
	if (iEntity <= 0 || !IsValidEntity(iEntity))
		return;
	
	// ===== 位置跟随（每帧）★ v2.33 仿 L4D2 六参数局部偏移+旋转 =====
	// 偏移是局部坐标(相对玩家朝向)：right*X + fwd*Y + up*Z → 旋转到世界
	float fPos[3];
	float fAng[3];
	float fViewAng[3];
	
	GetClientAbsOrigin(client, fPos);
	GetClientEyeAngles(client, fViewAng);
	
	float fOffX = g_cvOffX != null ? g_cvOffX.FloatValue : 0.0;
	float fOffY = g_cvOffY != null ? g_cvOffY.FloatValue : 0.0;
	float fOffZ = g_cvOffZ != null ? g_cvOffZ.FloatValue : 0.0;
	// ★ v2.35 pitch：优先 sm_legs_rot_pitch（新名），旧 sm_legs_pitch 改过才用（兼容）
	float fPitch = -89.0;
	if (g_cvRotPitch != null && g_cvRotPitch.FloatValue != -89.0)
		fPitch = g_cvRotPitch.FloatValue;
	else if (g_cvPitch != null && g_cvPitch.FloatValue != -89.0)
		fPitch = g_cvPitch.FloatValue;
	float fYaw   = g_cvRotYaw != null ? g_cvRotYaw.FloatValue : 0.0;
	float fRoll  = g_cvRotRoll != null ? g_cvRotRoll.FloatValue : 0.0;
	
	// 兼容旧 cvar：forward 叠加到局部 Y(前)，offset 叠加到局部 Z(下=负)
	if (g_cvForward != null) fOffY += g_cvForward.FloatValue;
	if (g_cvOffset != null)  fOffZ -= g_cvOffset.FloatValue;
	
	if (fOffX != 0.0 || fOffY != 0.0 || fOffZ != 0.0)
	{
		float fFwd[3], fRight[3], fUp[3];
		GetAngleVectors(fViewAng, fFwd, fRight, fUp);
		fPos[0] += fRight[0] * fOffX + fFwd[0] * fOffY + fUp[0] * fOffZ;
		fPos[1] += fRight[1] * fOffX + fFwd[1] * fOffY + fUp[1] * fOffZ;
		fPos[2] += fRight[2] * fOffX + fFwd[2] * fOffY + fUp[2] * fOffZ;
	}
	
	fAng[0] = fViewAng[0] + fPitch;
	fAng[1] = fViewAng[1] + fYaw;
	fAng[2] = fViewAng[2] + fRoll;
	
	TeleportEntity(iEntity, fPos, fAng, NULL_VECTOR);
	
	// ===== 动画同步（照仓库 CSGO_Aimbot：每帧）=====
	SyncAnimation(client, iEntity);
}

// ============ 仅 owner 可见 ============

public Action Hook_SetTransmit(int iEntity, int iClient)
{
	int iOwner = GetClientOfUserId(g_iLegsOwner[iEntity]);
	
	if (iOwner < 1 || !IsClientInGame(iOwner))
		return Plugin_Handled;
	
	if (iOwner != iClient)
		return Plugin_Handled;
	
	return Plugin_Continue;
}

// ============ 工具 ============

stock bool IsValidEntRef(int iEnt)
{
	return (iEnt != 0 && EntRefToEntIndex(iEnt) != INVALID_ENT_REFERENCE);
}

// ============ ★ v3.0 骨骼矩阵隐藏（手/头缩进身体）============
// 原理：客户端渲染前 C_BaseAnimating::SetupBones(client.dll) 计算骨骼矩阵，
//   存到 m_CachedBoneData 再 memcpy 到输出。我们 detour hook 它（post），
//   把腿实体 hand/arm/head 骨骼的矩阵平移改成根骨骼位置 → 手/头 mesh
//   被拉进躯干内部（被身体遮挡 → 视觉消失）。
//   缓存重算条件(m_iMostRecentModelBoneCounter != g_iModelBoneCounter)在走路时
//   不触发，所以改写持续生效（每次 SetupBones 返回后我们都会再写一次，双保险）。
// 偏移来源：client.dll 2023 legacy 逆向（SetupBones@RVA 0x1D3140）
//   m_EntIndex=+0x60, m_CachedBoneData=+0x2910, m_pStudioHdr=+0x294C
//   studiohdr_t: numbones@+0x9C, boneindex@+0xA0; mstudiobone_t=0xD8
// gamedata 签名: csgo_legs.games.txt
// ★ v3.3 定位三层 fallback：
//   ① gamedata 签名（library client）② gamedata 偏移（library client + RVA）
//   ③ 硬编码 0x101D3140（client.dll 无 .reloc 固定基址 0x10000000 + RVA 0x1D3140）
//   ⚠️ SourceMod 对 library "client" 模块解析不稳定（签名/偏移方式可能返回 null）
//     硬编码 + 前 4 字节特征验证是最终保底（特征 55 8B EC 83 = push ebp; mov ebp,esp; and esp,-16）
#define SETUPBONES_HARDCODE	0x101D3140
#define SETUPBONES_MAGIC	0x83EC8B55   // 小端: 55 8B EC 83

void InitBoneHide()
{
	Handle hGc = LoadGameConfigFile("csgo_legs.games");
	if (hGc == null)
		LogToFile("legs_debug.log", "[hook] 提示: gamedata/csgo_legs.games.txt 加载失败(将尝试硬编码)");
	
	Address pSetupBones = Address_Null;
	char sMethod[64];
	
	// ① gamedata 签名方式
	if (hGc != null)
	{
		pSetupBones = GameConfGetAddress(hGc, "CBaseAnimating::SetupBones");
		if (pSetupBones != Address_Null)
			strcopy(sMethod, sizeof(sMethod), "gamedata签名");
	}
	
	// ② gamedata 偏移方式（library client + RVA）
	if (pSetupBones == Address_Null && hGc != null)
	{
		pSetupBones = GameConfGetAddress(hGc, "CBaseAnimating::SetupBones_Off");
		if (pSetupBones != Address_Null)
			strcopy(sMethod, sizeof(sMethod), "gamedata偏移");
		else
			LogToFile("legs_debug.log", "[hook] 签名搜索失败(gamedata client库可能不可用)，尝试偏移方式也失败");
	}
	
	if (hGc != null)
		CloseHandle(hGc);
	
	// ③ 硬编码 fallback + 特征验证
	if (pSetupBones == Address_Null)
	{
		pSetupBones = view_as<Address>(SETUPBONES_HARDCODE);
		strcopy(sMethod, sizeof(sMethod), "硬编码(固定基址)");
		LogToFile("legs_debug.log", "[hook] gamedata 方式均失败，尝试硬编码 0x%X", SETUPBONES_HARDCODE);
		LogError("[Legs] gamedata 定位失败，使用硬编码 0x%X", SETUPBONES_HARDCODE);
	}
	
	// 验证目标地址前 4 字节是 SetupBones 特征（防止 detour 到错误地址崩溃）
	if (pSetupBones == Address_Null ||
		LoadFromAddress(pSetupBones, NumberType_Int32) != SETUPBONES_MAGIC)
	{
		// ★ v4.0 插件侧 hook 不可用（MIGI 下 client.dll 基址不定 + SourceMod 无 client 库）
		//   骨骼隐藏由 SourceMod 扩展 csgo_legs.ext.dll 负责（GetModuleHandle 拿基址 + detour）
		LogError("[Legs] 插件侧 SetupBones hook 不可用——请确认 csgo_legs.ext 扩展已加载");
		LogToFile("legs_debug.log", "[hook] 插件侧 hook 不可用，改走扩展方案 (csgo_legs.ext.dll)");
		LogToFile("legs_debug.log", "[hook] 请确认 SourceMod 已自动加载 csgo_legs.ext，再用 sm_legs_dbg 查看状态");
		return;
	}
	
	LogToFile("legs_debug.log", "[hook] SetupBones 定位成功: %s -> 0x%X", sMethod, pSetupBones);
	LogError("[Legs] SetupBones 定位成功: %s -> 0x%X", sMethod, pSetupBones);
	
	// bool __thiscall SetupBones(matrix3x4a_t *pBoneToWorldOut, int nMaxBones, int boneMask, float currentTime)
	g_hSetupBonesDetour = DHookCreateDetour(pSetupBones, CallConv_THISCALL, ReturnType_Bool, ThisPointer_Address);
	if (g_hSetupBonesDetour == null)
	{
		LogError("[Legs] SetupBones detour 创建失败");
		LogToFile("legs_debug.log", "[hook] 错误: SetupBones detour 创建失败");
		return;
	}
	
	DHookAddParam(g_hSetupBonesDetour, HookParamType_ObjectPtr);  // pBoneToWorldOut
	DHookAddParam(g_hSetupBonesDetour, HookParamType_Int);        // nMaxBones
	DHookAddParam(g_hSetupBonesDetour, HookParamType_Int);        // boneMask
	DHookAddParam(g_hSetupBonesDetour, HookParamType_Float);      // currentTime
	
	if (!DHookEnableDetour(g_hSetupBonesDetour, true, SetupBonesPost))
	{
		LogError("[Legs] SetupBones detour 启用失败");
		LogToFile("legs_debug.log", "[hook] 错误: SetupBones detour 启用失败");
		CloseHandle(g_hSetupBonesDetour);
		g_hSetupBonesDetour = null;
		return;
	}
	
	g_bBoneHideReady = true;
	PrintToServer("[Legs] SetupBones hook 已启用 @0x%X（骨骼隐藏就绪）", pSetupBones);
	LogToFile("legs_debug.log", "[hook] SetupBones hook 已启用 @0x%X（骨骼隐藏就绪）", pSetupBones);
	LogError("[Legs] SetupBones hook 已启用 @0x%X（骨骼隐藏就绪）", pSetupBones);
}

// 解析玩家模型骨骼名，返回需要隐藏的骨骼索引（hand/wrist/arm/clavicle/head/neck）
// MDL studiohdr v49: numbones@0x9C, boneindex@0xA0; mstudiobone_t=0xD8/条, sznameindex@+0
// 返回按模型缓存（g_hBoneCache: 模型路径 -> "idx1,idx2,..."）
int ParseModelBoneIndexes(const char[] sModel, int out[MAX_HIDE_BONES], int max)
{
	int count = 0;
	
	// 缓存命中直接解析
	if (g_hBoneCache != null)
	{
		char cached[128];
		if (g_hBoneCache.GetString(sModel, cached, sizeof(cached)) && cached[0] != '\0')
		{
			char parts[MAX_HIDE_BONES][8];
			int n = ExplodeString(cached, ",", parts, MAX_HIDE_BONES, 8);
			for (int i = 0; i < n && i < max; i++)
			{
				if (parts[i][0] != '\0')
					out[count++] = StringToInt(parts[i]);
			}
			return count;
		}
	}
	
	// 首次解析：读 MDL 骨骼表
	File hFile = OpenFile(sModel, "rb", true, "GAME");
	if (hFile == INVALID_HANDLE)
		return 0;
	
	int numBones = 0, boneIdx = 0;
	FileSeek(hFile, 0x9C, SEEK_SET);
	hFile.ReadInt32(numBones);
	hFile.ReadInt32(boneIdx);
	
	if (numBones >= 1 && numBones <= 256 && boneIdx > 0x100 && boneIdx < 0x400000)
	{
		for (int i = 0; i < numBones && count < max; i++)
		{
			int rec = boneIdx + i * 0xD8;
			FileSeek(hFile, rec, SEEK_SET);
			int sz;
			hFile.ReadInt32(sz);
			if (sz < 0 || sz > 0x1000)
				continue;
			
			FileSeek(hFile, rec + sz, SEEK_SET);
			char name[96];
			hFile.ReadString(name, sizeof(name));
			
			// 手/头相关骨骼（含上肢链）
			if (StrContains(name, "hand") != -1 || StrContains(name, "wrist") != -1 ||
			    StrContains(name, "arm") != -1 || StrContains(name, "clavicle") != -1 ||
			    StrContains(name, "head") != -1 || StrContains(name, "neck") != -1)
			{
				out[count++] = i;
			}
		}
	}
	CloseHandle(hFile);
	
	// 写缓存
	char val[128];
	val[0] = '\0';
	if (count > 0)
	{
		if (g_hBoneCache == null)
			g_hBoneCache = new StringMap();
		for (int i = 0; i < count; i++)
		{
			char tmp[12];
			Format(tmp, sizeof(tmp), "%s%d", (i > 0) ? "," : "", out[i]);
			StrCat(val, sizeof(val), tmp);
		}
		g_hBoneCache.SetString(sModel, val, true);
	}
	
	LogToFile("legs_debug.log", "[骨骼解析] 模型=%s 隐藏骨骼数=%d 索引[%s]", sModel, count, (count > 0) ? val : "无");
	PrintToServer("[Legs] 模型 %s 骨骼解析: %d 个隐藏骨骼(%s)", sModel, count,
		(count > 0) ? val : "无匹配");
	return count;
}

void ParseBonesForClient(int client, const char[] sModel)
{
	g_iHideBoneCount[client] = 0;
	if (g_cvHideBones != null && g_cvHideBones.IntValue == 0)
		return;
	// ★ v4.0 骨骼解析不再依赖插件自身 hook —— 解析结果写入控制文件供注入 DLL 使用
	g_iHideBoneCount[client] = ParseModelBoneIndexes(sModel, g_iHideBones[client], MAX_HIDE_BONES);
}

// ============ ★ v4.0 注入 DLL 通信（csgo_legs_ext.dll）============
// 架构（路线 B）：
//   SourceMod（服务器侧）→ 写控制文件 legs_ext_ctrl.txt → 注入 DLL（客户端侧）读
//   DLL GetModuleHandle("client.dll") 拿基址 → detour SetupBones → 按文件里的实体/骨骼改写矩阵
// 控制文件格式（写）：
//   第1行: 开关(1开 0关)
//   之后每行: 实体索引,骨骼1,骨骼2,...  （腿实体 + 要隐藏的骨骼索引）
// 状态文件（DLL 写，插件读显示）：
//   ready=1/0 base=0x.. setupbones=0x.. writes=N enabled=1/0 entities=N
void WriteLegsCtrl()
{
	// 相对路径 = 当前游戏目录（MIGI=migi/csgo，原版=csgo），与注入 DLL 读取路径一致
	File hFile = OpenFile("legs_ext_ctrl.txt", "w");
	if (hFile == null)
	{
		LogToFile("legs_debug.log", "[通信] 错误: 无法写 legs_ext_ctrl.txt");
		return;
	}
	
	// 第1行：开关（有腿实体且 sm_legs_hide_bones=1）
	int on = (g_cvHideBones == null || g_cvHideBones.IntValue != 0) ? 1 : 0;
	hFile.WriteLine("%d", on);
	
	// 每行：实体索引（DLL 运行时解析骨骼名，行内骨骼列表仅作参考）
	int nLines = 0;
	char dbg[512];
	dbg[0] = '\0';
	for (int client = 1; client <= MaxClients; client++)
	{
		int iEntity = EntRefToEntIndex(g_iLegsRef[client]);
		if (iEntity <= 0 || !IsValidEntity(iEntity))
			continue;
		
		char line[256];
		Format(line, sizeof(line), "%d", iEntity);
		// 附带解析到的骨骼（DLL 优先自己解析，无则用这里的）
		if (g_iHideBoneCount[client] > 0)
		{
			for (int i = 0; i < g_iHideBoneCount[client]; i++)
			{
				char tmp[16];
				Format(tmp, sizeof(tmp), ",%d", g_iHideBones[client][i]);
				StrCat(line, sizeof(line), tmp);
			}
		}
		hFile.WriteLine(line);
		nLines++;
		if (nLines <= 5)
			Format(dbg, sizeof(dbg), "%s%s", dbg, line);
	}
	CloseHandle(hFile);
	LogToFile("legs_debug.log", "[通信] 控制文件已写 %d 行 [%s]", nLines, dbg);
}

// 读扩展状态文件并返回是否就绪（用于诊断显示）
bool ReadLegsExtState(char[] buffer, int size)
{
	File hFile = OpenFile("legs_ext_state.txt", "r");
	if (hFile == null)
	{
		Format(buffer, size, "扩展状态文件不存在（csgo_legs.ext 未加载？请确认已放入 extensions\\ 且游戏重启）");
		return false;
	}
	
	char line[256];
	int n = 0;
	while (!IsEndOfFile(hFile) && hFile.ReadLine(line, sizeof(line)) && n < 20)
	{
		if (n == 0)
			Format(buffer, size, "%s", line);
		else
			Format(buffer, size, "%s | %s", buffer, line);
		n++;
	}
	CloseHandle(hFile);
	return true;
}

// SetupBones post-hook：把腿实体 hand/arm/head 骨骼矩阵平移到根骨骼位置
// 参数布局自适应：ThisPointer_Address 时 this 可能是 param1 或 param2（DHooks 版本相关）
//   首次命中时探测：读 param 指针 +0x60，取实体索引合理者 = this
//   探测结果缓存到 g_iHookLayout（避免每帧重复判断）
public MRESReturn SetupBonesPost(Handle hParams)
{
	if (!g_bBoneHideReady)
		return MRES_Ignored;
	
	Address thisEnt, pBones;
	
	if (g_iHookLayout == 0)
	{
		// 首次：探测参数布局（this 是实体指针，+0x60 是实体索引小整数）
		Address a1 = DHookGetParamAddress(hParams, 1);
		Address a2 = DHookGetParamAddress(hParams, 2);
		if (a1 == Address_Null || a2 == Address_Null)
			return MRES_Ignored;
		
		int i1 = LoadFromAddress(a1 + view_as<Address>(CLIENT_ENTINDEX_OFF), NumberType_Int32);
		int i2 = LoadFromAddress(a2 + view_as<Address>(CLIENT_ENTINDEX_OFF), NumberType_Int32);
		
		if (i1 >= 1 && i1 <= 2048 && (i2 < 1 || i2 > 2048))
			g_iHookLayout = 1;   // param1=this, param2=pBoneToWorldOut
		else if (i2 >= 1 && i2 <= 2048 && (i1 < 1 || i1 > 2048))
			g_iHookLayout = 2;   // param2=this, param1=pBoneToWorldOut
		else
			return MRES_Ignored; // 探测失败（罕见），等下次
		
		PrintToServer("[Legs] SetupBones 参数布局=%d (this@P%d)", g_iHookLayout, g_iHookLayout);
		LogToFile("legs_debug.log", "[hook] SetupBones 参数布局探测: 布局=%d (this@P%d, pBones@P%d)",
			g_iHookLayout, g_iHookLayout, (g_iHookLayout == 1) ? 2 : 1);
		LogError("[Legs] SetupBones 参数布局探测: 布局=%d (this@P%d)", g_iHookLayout, g_iHookLayout);
	}
	
	if (g_iHookLayout == 1)
	{
		thisEnt = DHookGetParamAddress(hParams, 1);
		pBones  = DHookGetParamAddress(hParams, 2);
	}
	else
	{
		thisEnt = DHookGetParamAddress(hParams, 2);
		pBones  = DHookGetParamAddress(hParams, 1);
	}
	
	if (thisEnt == Address_Null || pBones == Address_Null)
		return MRES_Ignored;
	
	// 客户端实体索引（this+0x60）
	int entIndex = LoadFromAddress(thisEnt + view_as<Address>(CLIENT_ENTINDEX_OFF), NumberType_Int32);
	if (entIndex < 1 || entIndex > 2048)
		return MRES_Ignored;
	
	// 快速路径：该实体是否是腿实体（服务器索引 == 客户端索引）
	int client = g_iBoneHideEnt[entIndex];
	if (client < 1)
		return MRES_Ignored;
	
	int nHide = g_iHideBoneCount[client];
	if (nHide <= 0)
		return MRES_Ignored;
	
	// 根骨骼(0)平移 = "身体内部"目标位置
	int rx = LoadFromAddress(pBones + view_as<Address>(BONE_TRANS_X), NumberType_Int32);
	int ry = LoadFromAddress(pBones + view_as<Address>(BONE_TRANS_Y), NumberType_Int32);
	int rz = LoadFromAddress(pBones + view_as<Address>(BONE_TRANS_Z), NumberType_Int32);
	
	// ★ 诊断：首次改写前记录一次（验证参数/索引/骨骼解析）
	if (!g_bBoneDiagLogged)
	{
		g_bBoneDiagLogged = true;
		char bones[128];
		bones[0] = '\0';
		for (int i = 0; i < nHide; i++)
		{
			char tmp[12];
			Format(tmp, sizeof(tmp), "%s%d", (i > 0) ? "," : "", g_iHideBones[client][i]);
			StrCat(bones, sizeof(bones), tmp);
		}
		PrintToServer("[Legs] 骨骼隐藏生效: ent=%d client=%d 骨骼[%s] root=(%.0f,%.0f,%.0f)",
			entIndex, client, bones,
			view_as<float>(rx), view_as<float>(ry), view_as<float>(rz));
		LogToFile("legs_debug.log", "[生效] 骨骼隐藏改写: ent=%d client=%d 骨骼[%s] root=(%.0f,%.0f,%.0f)",
			entIndex, client, bones,
			view_as<float>(rx), view_as<float>(ry), view_as<float>(rz));
		LogError("[Legs] 骨骼隐藏改写: ent=%d client=%d 骨骼[%s] root=(%.0f,%.0f,%.0f)",
			entIndex, client, bones,
			view_as<float>(rx), view_as<float>(ry), view_as<float>(rz));
	}
	
	// 改写目标骨骼平移 → 根骨骼位置（mesh 缩进躯干）
	for (int i = 0; i < nHide; i++)
	{
		int bone = g_iHideBones[client][i];
		if (bone <= 0)
			continue;   // 不动根骨骼
		Address mat = pBones + view_as<Address>(bone * BONE_MATRIX_STRIDE);
		StoreToAddress(mat + view_as<Address>(BONE_TRANS_X), rx, NumberType_Int32);
		StoreToAddress(mat + view_as<Address>(BONE_TRANS_Y), ry, NumberType_Int32);
		StoreToAddress(mat + view_as<Address>(BONE_TRANS_Z), rz, NumberType_Int32);
	}
	
	return MRES_Ignored;
}

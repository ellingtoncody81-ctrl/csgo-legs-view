Msg("Activating Survivor Legs script\n");

local default_folder = "survivor_legs";
local info_path = default_folder+"/info.txt";
local settings_path = default_folder+"/settings.cfg";

/*local shotgunMdls = [
	null,	//	Pumpshotgun
	null,	//	Spas
	null,	//	Chromeshotgun
	null,	//	Autoshotgun
];
if (IsModelPrecached("models/w_models/weapons/w_shotgun.mdl"))
{ shotgunMdls[0] = GetModelIndex("models/w_models/weapons/w_shotgun.mdl"); }
else
{ shotgunMdls[0] = PrecacheModel("models/w_models/weapons/w_shotgun.mdl"); }*/

survivorlegs <-
{
	Settings =
	{
		LegsOffsetX = 0.0,
		LegsOffsetY = 0.0,
		LegsOffsetZ = -20.0,
		LegsRotationPitch = -89.0,
		LegsRotationYaw = 0.0,
		LegsRotationRoll = 0.0,
		//LegsFadeDist = 24.0,
		ShowItemsOnLegs = true,
		RenderLegsOnLowDetail = true,
		ILikeMyLegsCalm = false,
		BreakLegsBecauseImAnIdiot = false
	}
	
	function ParseConfigFile()
	{
		local tData;

		local function SerializeSettings()
		{
			local sData = "{";
			foreach (key, val in Settings)
			{
				if (key == "BreakLegsBecauseImAnIdiot") continue;
				switch (typeof val)
				{
				case "string":
					sData = format("%s\n\t%s = \"%s\"", sData, key, val);
					break;
				
				case "float":
					sData = format("%s\n\t%s = %.2f", sData, key, val);
					break;
				
				case "integer":
				case "bool":
					sData = sData + "\n\t" + key + " = " + val;
					break;
				}
			}
			sData = sData + "\n}";
			StringToFile(settings_path, sData);
		}

		if (tData = FileToString(settings_path))
		{
			try {
				tData = compilestring("return " + tData)();
				local hasMissingKey = false;
				foreach (key, val in Settings)
				{
					if (key in tData)
					{
						Settings[key] = tData[key];
					}
					else if (!hasMissingKey && key != "BreakLegsBecauseImAnIdiot")
					{ hasMissingKey = true; }
				}
				if (hasMissingKey)
				{ SerializeSettings(); }
			}
			catch (error) {
				SerializeSettings();
			}
		}
		else
		{
			SerializeSettings();
		}
	}
	
	function OnGameEvent_player_death( params )
	{
		if (!("userid" in params)) return;
		
		local client = GetPlayerFromUserID( params["userid"] );
		//local isPlyBotCheck = developer() ? false : IsPlayerABot(client);
		//if (client == null || !client.IsValid() || !client.IsSurvivor() || isPlyBotCheck || client.IsDead() || client.IsDying()) return;
		if (client == null || !client.IsValid() || !client.IsSurvivor() || IsPlayerABot(client) || client.IsDead() || client.IsDying()) return;
		if (!client.ValidateScriptScope()) return;
		
		local clScope = client.GetScriptScope();
		if (!("SLegs" in clScope)) return;
		
		local legs = clScope.SLegs;
		if (legs == null || !legs.IsValid()) return;
		
		DoEntFire("!self", "Kill", "", 0.0, null, legs);
		clScope.SLegs <- null;
		
		if ("SLegsHack" in clScope)
		{
			local legHack = clScope.SLegsHack;
			if (legHack != null && legHack.IsValid())
			{
				DoEntFire("!self", "Kill", "", 0.0, null, legHack);
				clScope.legHack <- null;
			}
		}
	}
	
	function OnGameEvent_player_spawn( params )
	{
		if (!("userid" in params)) return;
		
		local client = GetPlayerFromUserID( params["userid"] );
		//local isPlyBotCheck = developer() ? false : IsPlayerABot(client);
		//if (client == null || !client.IsValid() || !client.IsSurvivor() || isPlyBotCheck || client.IsDead() || client.IsDying()) return;
		if (client == null || !client.IsValid() || !client.IsSurvivor() || IsPlayerABot(client) || client.IsDead() || client.IsDying()) return;
		if (!client.ValidateScriptScope()) return;
		
		local clScope = client.GetScriptScope();
		if (("SLegs" in clScope))
		{
			local legs = clScope.SLegs;
			if (legs != null && legs.IsValid()) return;
		}
		
		local clScope = client.GetScriptScope();
		if (!("SLegsInit" in clScope))
		{
			clScope.SLegsInit <- function()
			{
				if (!self.IsSurvivor() || self.IsDead() || self.IsDying()) return;
				
				survivorlegs.AttachLegs(self);
			}
		}
		DoEntFire("!self", "CallScriptFunction", "SLegsInit", 0.0, null, client);
	}
	
	function OnGameEvent_player_team( params )
	{
		if (!("userid" in params)) return;
		
		local client = GetPlayerFromUserID( params["userid"] );
		if (client == null || !client.IsValid()) return;
		if (!client.ValidateScriptScope()) return;
		
		local clScope = client.GetScriptScope();
		if (!("SLegs" in clScope)) return;
		
		local legs = clScope.SLegs;
		if (legs == null || !legs.IsValid()) return;
		
		DoEntFire("!self", "Kill", "", 0.0, null, legs);
		clScope.SLegs <- null;
		
		if ("SLegsHack" in clScope)
		{
			local legHack = clScope.SLegsHack;
			if (legHack != null && legHack.IsValid())
			{
				DoEntFire("!self", "Kill", "", 0.0, null, legHack);
				clScope.legHack <- null;
			}
		}
	}
	
	function AttachLegs(client)
	{
		if (!client.ValidateScriptScope()) return;
		local clScope = client.GetScriptScope();
		
		local model = NetProps.GetPropString(client, "m_ModelName");
		
		if ("SLegs" in clScope)
		{
			local legs = clScope.SLegs;
			if (legs != null && legs.IsValid())
			{
				legs.SetModel(model);
				if (legs.ValidateScriptScope())
				{
					local sLegsScope = legs.GetScriptScope();
					foreach (key, val in sLegsScope.storedTree)
					{
						if (val == null || !val.IsValid()) continue;
						
						local className = val.GetClassname();
						local visArr = sLegsScope.GetModelVis(key, className);
						if (visArr == null) continue;
						
						if (sLegsScope.visTree[key] == null || !sLegsScope.visTree[key].IsValid()) { SpawnVis(key); }
						
						sLegsScope.ReattachVis(sLegsScope.visTree[key], visArr);
					}
				}
				return;
			}
		}
		
		local fPos = client.GetOrigin();
		//local fAng = client.EyeAngles();
		//local entAng = entity.GetAngles();
		
		// https://forums.alliedmods.net/showpost.php?p=2737781&postcount=21
		// Taking a page out of L4D hats, parent the legs to an info_target that's parented to the actual player
		// so the glow does not occur
		if (("SLegsHack" in clScope))
		{ if (clScope.SLegsHack != null && clScope.SLegsHack.IsValid()) DoEntFire("!self", "Kill", "", 0.0, null, clScope.SLegsHack); }
		// must always kill and recreate otherwise it won't work for survivor takeover
		local targTbl = { origin = fPos.ToKVString(), spawnflags = 1 };
		if (!Settings.RenderLegsOnLowDetail)
		{ targTbl.mincpulevel <- 2; targTbl.maxcpulevel <- 3; }
		local target = SpawnEntityFromTable("info_target", targTbl);
		DoEntFire("!self", "SetParent", "!activator", 0.0, client, target); // Parent target to the player
		clScope.SLegsHack <- target;
		
		//local fadeOffsets = Settings.LegsOffsetX + Settings.LegsOffsetY + Settings.LegsOffsetZ + 4.0; // LegsOffsetZ is negative, use LegsFadeDist
		local legsTbl = {
			origin = fPos.ToKVString(),
			model = model,
			solid = 0,
			spawnflags = 128 | 256,	// SF_DYNAMICPROP_NO_VPHYSICS | SF_DYNAMICPROP_DISABLE_COLLISION
			//fademindist = Settings.LegsFadeDist,
			//fademaxdist = Settings.LegsFadeDist,
			fademindist = 8,
			fademaxdist = 8, // the test stairs on my test map make the legs sink, making them hidden. so no 1 for now
			//shadowcastdist = 1,
			effects = (1 << 4) + (1 << 6) + (1 << 11) + (1 << 13),	// EF_NOSHADOW | EF_NORECEIVESHADOW | EF_NOSHADOWDEPTH | EF_NOFLASHLIGHT
			vscripts = "entlegs_scr",
			thinkfunction = "LegsThink"
		};
		if (!Settings.RenderLegsOnLowDetail) // Simulate legs not rendering on Effect Detail Low just like original L4D1
		{ legsTbl.mincpulevel <- 2; legsTbl.maxcpulevel <- 3; }
		
		local entity = SpawnEntityFromTable("prop_dynamic_override", legsTbl);
		if (entity == null || !entity.IsValid()) return;
		
		if (!entity.ValidateScriptScope())
		{
			DoEntFire("!self", "Kill", "", 0.0, null, entity);
			return;
		}
		local entScope = entity.GetScriptScope();
		entScope.LegsOwner <- client;
		entScope.modelIdx <- NetProps.GetPropInt(client, "m_nModelIndex");
		clScope.SLegs <- entity;
		
		DoEntFire("!self", "SetParent", "!activator", 0.0, target, entity); // Parent legs to the target
		//NetProps.SetPropEntity(entity, "m_hOwnerEntity", client);
		
		//NetProps.SetPropVector(entity, "m_Collision.m_vecMins", Vector(0,0,0));
		//NetProps.SetPropVector(entity, "m_Collision.m_vecMins", Vector(0,0,-2048));
		// ^ HACK !! this buries the legs' target origin for +use WAY DEEP in the floor without disrupting the
		// origin of the legs to fix the USE blocking
		// TODO: Does not seem to work consistently, dont use
		//NetProps.SetPropVector(entity, "m_Collision.m_vecMaxs", Vector(0,0,0));
		//NetProps.SetPropVector(entity, "m_Collision.m_vecSpecifiedSurroundingMins", Vector(0,0,0));
		//NetProps.SetPropVector(entity, "m_Collision.m_vecSpecifiedSurroundingMaxs", Vector(0,0,0));
		
		NetProps.SetPropInt(entity, "m_MoveType", 0); // MOVETYPE_NONE
		
		NetProps.SetPropInt(entity, "m_iEFlags", NetProps.GetPropInt(entity, "m_iEFlags") | (1<<25)); // EFL_DONTBLOCKLOS
		
		NetProps.SetPropInt(entity, "m_Collision.m_nSolidType", 6);
		DoEntFire("!self", "RunScriptCode", "NetProps.SetPropInt(self,\"m_nSolidType\",0)", 0.0, null, entity);
		// ^ This is what Lux used to fix the bug with +USE getting blocked by the legs, but
		// it seems it also delays the legs from being visible on spawn
		
		NetProps.SetPropInt(entity, "m_bClientSideAnimation", 1);
		
		OffsetLegs(target);
		// Offset the target instead of the legs for proper alignment
		
		//local fFlags = NetProps.GetPropInt(entity, "m_fFlags");
		//fFlags = fFlags | (1<<31);
		//NetProps.SetPropInt(entity, "m_fFlags", fFlags);
		
		NetProps.SetPropInt(entity, "m_noGhostCollision", 1);
		NetProps.SetPropInt(entity, "m_bClientPhysics", 0);
		
		//local usSolidFlags = NetProps.GetPropInt(entity, "m_Collision.m_usSolidFlags");
		//usSolidFlags = usSolidFlags | 0x0010; // FSOLID_NOT_STANDABLE
		//NetProps.SetPropInt(entity, "m_Collision.m_usSolidFlags", usSolidFlags);
		//reminder to test out m_nHitboxSet
		
		//DoEntFire("!self", "StartGlowing", "", 0.0, null, entity);
		//DoEntFire("!self", "StopGlowing", "", 0.0, null, entity);
		
		//SDKHook(iEntity, SDKHook_SetTransmit, HideModel);
		// ^ big rip, but next best thing is fademindist and fademaxdist + info_target parenting
	}
	
	function OffsetLegs(target)
	{
		DoEntFire("!self", "RunScriptCode", 
		"self.SetLocalOrigin(Vector("+Settings.LegsOffsetX+","+Settings.LegsOffsetY+","+Settings.LegsOffsetZ+"))", 0.0, null, target);
		DoEntFire("!self", "RunScriptCode", 
		"self.SetLocalAngles(QAngle("+Settings.LegsRotationPitch+","+Settings.LegsRotationYaw+","+Settings.LegsRotationRoll+"))", 0.0, null, target);
	}
	
	/*function PerformTeleport(target, origin)
	{
		local keyValues = { target = "!activator", origin = origin.ToKVString() }
		
		local point_tele = SpawnEntityFromTable("point_teleport", keyValues);
		DoEntFire("!self", "Teleport", "", 0.0, target, point_tele);
		DoEntFire("!self", "Kill", "", 0.0, null, point_tele);
	}*/
	
	/*function OnGameEvent_player_say( params )
	{
		local dev = developer();
		
		if (!dev) return;
		
		local client = null;
		if ("userid" in params)
		client = GetPlayerFromUserID(params["userid"]);
		
		local chat_result = "";
		if ("text" in params)
		chat_result = params["text"];
		
		if (dev) printl("SURVIVORLEGS: We've got it: "+chat_result);
		
		if (chat_result.find("!") == 0 || chat_result.find("/") == 0)
		{
			chat_result = chat_result.slice(1)
		}
		else
		{
			return;
		}
		
		switch (chat_result)
		{
			case "legs_add":
				AttachLegs(client);
				if (dev) printl("attached legs");
				break;
			default:
				break;
		}
	}*/
	
	function CheckAnimation(client)
	{
		local sModel_29_Check = NetProps.GetPropString(client, "m_ModelName")[29];
		
		local health = NetProps.GetPropInt(client, "m_iHealth");
		local healthBuffer = client.GetHealthBuffer();
		//local isAdrenAct = NetProps.GetPropInt(client, "m_bAdrenalineActive");
		
		local iSequence = NetProps.GetPropInt(client, "m_nSequence");
		local isCalm = Settings.ILikeMyLegsCalm || !!(NetProps.GetPropInt(client, "m_isCalm"));
		local isLimping = !!((health + healthBuffer + 0.0) < 
		Convars.GetFloat("survivor_limp_health"))/* && !isAdrenAct*/;
		
		local buttons = NetProps.GetPropInt(client, "m_nButtons");
		//printl("m_nButtons: "+buttons);
		
		// detect via netprops or m_nButtons instead of replacing sequences to fix crouching anims being delayed
		// AND reduce shitload of work individually checking for every single sequence
		local isWalking = !!(buttons & (1 << 17)) || // IN_SPEED, i know the name doesn't fit but it's literally called that
		(/*!isAdrenAct && */NetProps.GetPropInt(client, "m_isGoingToDie") && health == 1 && healthBuffer == 0.0); 
		local vel = NetProps.GetPropVector(client, "m_vecVelocity");
		//local isMoving = !!(buttons & (1 << 3) || buttons & (1 << 4) ||		// IN_FORWARD, IN_BACK
		//				buttons & (1 << 9) || buttons & (1 << 10))			// IN_MOVELEFT, IN_MOVERIGHT
		local isMoving = Settings.BreakLegsBecauseImAnIdiot || !!(vel.x != 0.0 || vel.y != 0.0 || vel.z != 0.0);
		//local isDucking = !!(buttons & (1 << 2)); // IN_DUCK
		local duckedVar = !!(NetProps.GetPropInt(client, "m_Local.m_bDucked"));
		local duckingVar = !!(NetProps.GetPropInt(client, "m_Local.m_bDucking"));
		// one problem with this system is if a surv that has been incapped once reaches 1 hp
		// they'll limp without IN_SPEED being held, this results in the faster limp run seq than
		// the appropriate limp walk seq
		// what's mad about this is it's not determined by m_currentReviveCount AND it's on a hidden timer
		// ...oh well NOBODY WILL NOTICE >:DDDDDDDDD
		// 6/2/2023: fixed, there's also code to fix the adrenaline low-hp animations too but
		// actual adren TP animation is broken too so no need
		
		// 'b'		= nick, legs edited and retested on 9/24/2022
		// 'd', 'w'	= rochelle, adawong (custom plugin survivor), legs edited and retested on 9/24/2022
		// 'c'		= coach, legs edited and retested on 9/24/2022
		// 'h'		= ellis, legs edited and retested on 9/24/2022
		// 'v'		= bill, legs edited and retested on 9/24/2022
		// 'n'		= zoey, legs edited and retested on 9/24/2022
		// 'e'		= francis, legs edited and retested on 9/24/2022
		// 'a'		= louis, legs edited and retested on 9/24/2022
		
		// Check buttons instead of animations for crouching, as the crouch anims are delayed
		// lmao this system, i am so sorry
		// be CAREFUL with the breaks as well, they're basically }'s but it doesn't throw an error if you miss em
		// i'm so traumatized by the break requirement that i put breaks even on the returns because
		// one time I didn't it DID matter and it BROKE shit
		switch (!!(NetProps.GetPropInt(client, "m_fFlags") & (1 << 0))) // FL_ONGROUND
		{
			case true: // is on ground
			{
				//switch (isDucking)
				switch ((duckedVar && !duckingVar) || (!duckedVar && duckingVar)) // this fix was entirely discovered by accident
				{
					case true:	// is ducking
					{
						switch (isMoving)
						{
							case true:	// is moving while ducked
								switch (sModel_29_Check)
								{
									case 'b': {return 190;	break;}		//CrouchWalk_SMG				ACT_RUN_CROUCH_SMG
									case 'd':
									case 'w': {return 202;	break;}		//CrouchWalk_SMG				ACT_RUN_CROUCH_SMG
									case 'c': {return 162;	break;}		//CrouchWalk_Sniper				ACT_RUN_CROUCH_SNIPER
									case 'h': {return 187;	break;}		//CrouchWalk_Sniper				ACT_RUN_CROUCH_SNIPER
									case 'v': {return 164;	break;}		//CrouchWalk_SMG				ACT_RUN_CROUCH_SMG
									case 'n': {return 176;	break;}		//CrouchWalk_Elites				ACT_RUN_CROUCH_ELITES
									case 'e': {return 158;	break;}		//CrouchWalk_Pistol				ACT_RUN_CROUCH_PISTOL
									case 'a': {return 170;	break;}		//CrouchWalk_SMG				ACT_RUN_CROUCH_SMG
								}
							default:	// is NOT moving while ducked
								switch (sModel_29_Check)
								{
									case 'b': {return 46;	break;}		//Idle_Crouching_Pistol			ACT_CROUCHIDLE_PISTOL
									case 'd':
									case 'w': {return 56;	break;}		//Idle_Crouching_Pistol			ACT_CROUCHIDLE_PISTOL
									case 'c': {return 52;	break;}		//Idle_Crouching_SniperZoomed	ACT_CROUCHIDLE_SNIPER_ZOOMED
									case 'h': {return 54;	break;}		//Idle_Crouching_SniperZoomed	ACT_CROUCHIDLE_SNIPER_ZOOMED
									case 'v': {return 43;	break;}		//Idle_Crouching_Pistol			ACT_CROUCHIDLE_PISTOL
									case 'n': {return 69;	break;}		//Idle_Crouching_SMG			ACT_CROUCHIDLE_SMG
									case 'e': {return 52;	break;}		//Idle_Crouching_Pistol			ACT_CROUCHIDLE_PISTOL
									case 'a': {return 49;	break;}		//Idle_Crouching_Pistol			ACT_CROUCHIDLE_PISTOL
								}
						}
						break;
					}
					default:	// is NOT ducking
					{
						switch (isMoving)
						{
							case true:	// is moving
							{
								switch (isLimping)
								{
									case true:	// is limping
									{
										switch (isWalking)
										{
											case true:	// is walking
												switch (sModel_29_Check)
												{
													case 'b': {return 306;	break;}	//LimpWalk_Sniper	ACT_WALK_INJURED_SNIPER
													case 'd':
													case 'w': {return 142;	break;}	//Walk_Elites		ACT_WALK_ELITES
													case 'c': {return 120;	break;}	//Walk_Elites		ACT_WALK_ELITES
													case 'h': {return 127;	break;}	//Walk_Elites		ACT_WALK_ELITES
													case 'v': {return 122;	break;}	//Walk_Elites		ACT_WALK_ELITES
													case 'n': {return 161;	break;}	//Walk_SMG			ACT_WALK_SMG
													case 'e': {return 128;	break;}	//Walk_Pistol		ACT_WALK_PISTOL
													case 'a': {return 125;	break;}	//Walk_Pistol		ACT_WALK_PISTOL
												}
											default:	// is NOT walking
												switch (sModel_29_Check)
												{
													case 'b': {return 319;	break;}	//LimpRun_SMG		ACT_RUN_INJURED_SMG
													case 'd':
													case 'w': {return 331;	break;}	//LimpRun_SMG		ACT_RUN_INJURED_SMG
													case 'c': {return 313;	break;}	//LimpRun_Sniper	ACT_RUN_INJURED_SNIPER
													case 'h': {return 318;	break;}	//LimpRun_Sniper	ACT_RUN_INJURED_SNIPER
													case 'v': {return 651;	break;}	//LimpRun_Sniper_Military	ACT_RUN_INJURED_SNIPER_MILITARY
													case 'n': {return 203;	break;}	//Run_Pistol		ACT_RUN_PISTOL
													case 'e': {return 266;	break;}	//LimpRun_Rifle		ACT_RUN_INJURED_RIFLE
													case 'a': {return 264;	break;}	//LimpRun_Rifle		ACT_RUN_INJURED_RIFLE
												}
										}
										break;
									}
									default:	// is NOT limping
										switch (isWalking)
										{
											case true:	// is walking
												switch (sModel_29_Check)
												{
													case 'b': {return 130;	break;}	//Walk_Pistol		ACT_WALK_PISTOL
													case 'd':
													case 'w': {return 142;	break;}	//Walk_Elites		ACT_WALK_ELITES
													case 'c': {return 120;	break;}	//Walk_Elites		ACT_WALK_ELITES
													case 'h': {return 160;	break;}	//Walk_Sniper		ACT_WALK_SNIPER
													case 'v': {return 122;	break;}	//Walk_Elites		ACT_WALK_ELITES
													case 'n': {return 161;	break;}	//Walk_SMG			ACT_WALK_SMG
													case 'e': {return 128;	break;}	//Walk_Pistol		ACT_WALK_PISTOL
													case 'a': {return 128;	break;}	//Walk_Elites		ACT_WALK_ELITES
												}
											default:	// is NOT walking
												switch (sModel_29_Check)
												{
													case 'b': {return 214;	break;}	//Run_Pistol		ACT_RUN_PISTOL
													case 'd':
													case 'w': {return 229;	break;}	//Run_Elites		ACT_RUN_ELITES
													case 'c': {return 233;	break;}	//Run_PumpShotgun	ACT_RUN_PUMPSHOTGUN
													case 'h': {return 208;	break;}	//Run_Elites		ACT_RUN_ELITES
													case 'v': {return 179;	break;}	//Run_Pistol		ACT_RUN_PISTOL
													case 'n': {return 203;	break;}	//Run_Pistol		ACT_RUN_PISTOL
													case 'e': {return 188;	break;}	//Run_Pistol		ACT_RUN_PISTOL
													case 'a': {return 185;	break;}	//Run_Pistol		ACT_RUN_PISTOL
												}
										}
										break;
								}
								break;
							}
							default:	// is NOT moving
							{
								switch (isLimping)
								{
									case true:	// is limping
										switch (sModel_29_Check)
										{
											case 'b': {return 124;	break;}	//Idle_Injured_SniperZoomed	ACT_IDLE_INJURED_SNIPER_ZOOMED
											case 'd':
											case 'w': {return 132;	break;}	//Idle_Injured_SniperZoomed	ACT_IDLE_INJURED_SNIPER_ZOOMED
											case 'c': {return 110;	break;}	//Idle_Injured_SniperZoomed	ACT_IDLE_INJURED_SNIPER_ZOOMED
											case 'h': {return 107;	break;}	//Idle_Injured_PumpShotgun	ACT_IDLE_INJURED_PUMPSHOTGUN
											case 'v': {return 84;	break;}	//Idle_Injured_Pistol		ACT_IDLE_INJURED_PISTOL
											case 'n': {return 132;	break;}	//Idle_Injured_SniperZoomed	ACT_IDLE_INJURED_SNIPER_ZOOMED
											case 'e': {return 99;	break;}	//Idle_Injured_Rifle		ACT_IDLE_INJURED_RIFLE
											case 'a': {return 93;	break;}	//Idle_Injured_Elites		ACT_IDLE_INJURED_ELITES
										}
									default:	// is NOT limping
									{
										switch (sModel_29_Check)
										{
											case 'b':
											{
												switch (iSequence)
												{
													case 21:	//	Idle_Standing_PumpShotgun			ACT_IDLE_PUMPSHOTGUN
														if (!Settings.ILikeMyLegsCalm)
														{
															return 18;	//Idle_Standing_Shotgun				ACT_IDLE_SHOTGUN
															break;
														}
													case 18:	//	Idle_Standing_Shotgun		ACT_IDLE_SHOTGUN
														if (!Settings.ILikeMyLegsCalm)
															break;	// Shotgun anims look nice, don't replace
													default:
													{
														switch (isCalm)
														{
															case true:	// calm
																return 7;	//Idle_Standing_Pistol			ACT_IDLE_PISTOL
																break;
															default:	// not calm
																return 30;	//Idle_Standing_SMG				ACT_IDLE_SMG
																break;
														}
														break;
													}
												}
												break;
											}
											case 'd':
											case 'w':
											{
												switch (iSequence)
												{
													case 23:	//	Idle_Standing_PumpShotgun		ACT_IDLE_PUMPSHOTGUN
														if (!Settings.ILikeMyLegsCalm)
														{
															return 20;	//Idle_Standing_Shotgun				ACT_IDLE_SHOTGUN
															break;
														}
													case 20:	//	Idle_Standing_Shotgun			ACT_IDLE_SHOTGUN
														if (!Settings.ILikeMyLegsCalm)
															break;	// Shotgun anims look nice, don't replace
													default:
													{
														switch (isCalm)
														{
															case true:	// calm
																return 7;	//Idle_Standing_Elites			ACT_IDLE_ELITES
																break;
															default:	// not calm
																return 32;	//Idle_Standing_SMG				ACT_IDLE_SMG
																break;
														}
														break;
													}
												}
												break;
											}
											case 'c':
											{
												switch (isCalm)
												{
													case true:	// calm
														return 16;	//Idle_Standing_Shotgun			ACT_IDLE_SHOTGUN
														break;
													default:	// not calm
														return 24;	//Idle_Standing_Sniper_MilitaryZoomed	ACT_IDLE_SNIPER_MILITARYZOOMED
														break;
												}
												break;
											}
											case 'h':
											{
												switch (iSequence)
												{
													case 39:	//	Idle_Standing_PumpShotgun		ACT_IDLE_PUMPSHOTGUN
														if (!Settings.ILikeMyLegsCalm)
														{
															return 15;	//Idle_Standing_Shotgun				ACT_IDLE_SHOTGUN
															break;
														}
													case 15:	//	Idle_Standing_Shotgun			ACT_IDLE_SHOTGUN
														if (!Settings.ILikeMyLegsCalm)
															break;	// Shotgun anims look nice, don't replace
													default:
													{
														switch (isCalm)
														{
															case true:	// calm
																return 12;	//Idle_Standing_Elites			ACT_IDLE_ELITES
																break;
															default:	// not calm
																return 30;	//Idle_Standing_Sniper			ACT_IDLE_SNIPER
																break;
														}
														break;
													}
												}
												break;
											}
											case 'v':
											{
												switch (iSequence)
												{
													case 21:	//	Idle_Standing_PumpShotgun		ACT_IDLE_PUMPSHOTGUN
														if (!Settings.ILikeMyLegsCalm)
														{
															return 18;	//Idle_Standing_Shotgun				ACT_IDLE_SHOTGUN
															break;
														}
													case 18:	//	Idle_Standing_Shotgun			ACT_IDLE_SHOTGUN
														if (!Settings.ILikeMyLegsCalm)
															break;	// Shotgun anims look nice, don't replace
													default:
													{
														switch (isCalm)
														{
															case true:	// calm
																return 12;	//Idle_Standing_Elites			ACT_IDLE_ELITES
																break;
															default:	// not calm
																return 30;	//Idle_Standing_SMG				ACT_IDLE_SMG
																break;
														}
														break;
													}
												}
												break;
											}
											case 'n':
											{
												switch (iSequence)
												{
													default:
													{
														switch (isCalm)
														{
															case true:	// calm
																return 9;	//Idle_Standing_Pistol			ACT_IDLE_PISTOL
																break;
															default:	// not calm
																return 30;	//Idle_Standing_SMG				ACT_IDLE_SMG
																break;
														}
														break;
													}
												}
												break;
											}
											case 'e':
											{
												switch (iSequence)
												{
													case 30:	//	Idle_Standing_PumpShotgun		ACT_IDLE_PUMPSHOTGUN
														if (!Settings.ILikeMyLegsCalm)
														{
															return 27;	//Idle_Standing_Shotgun				ACT_IDLE_SHOTGUN
															break;
														}
													case 27:	//	Idle_Standing_Shotgun			ACT_IDLE_SHOTGUN
														if (!Settings.ILikeMyLegsCalm)
															break;	// Shotgun anims look nice, don't replace
													default:
													{
														switch (isCalm)
														{
															case true:	// calm
																return 22;	//Idle_Standing_Elites			ACT_IDLE_ELITES
																break;
															default:	// not calm
																return 19;	//Idle_Standing_Pistol			ACT_IDLE_PISTOL
																break;
														}
														break;
													}
												}
												break;
											}
											case 'a':
											{
												switch (iSequence)
												{
													case 27:	//	Idle_Standing_PumpShotgun		ACT_IDLE_PUMPSHOTGUN
														if (!Settings.ILikeMyLegsCalm)
														{
															return 24;	//Idle_Standing_Shotgun				ACT_IDLE_SHOTGUN
															break;
														}
													case 24:	//	Idle_Standing_Shotgun			ACT_IDLE_SHOTGUN
														if (!Settings.ILikeMyLegsCalm)
															break;	// Shotgun anims look nice, don't replace
													default:
													{
														switch (isCalm)
														{
															case true:	// calm
																return 19;	//Idle_Standing_Elites			ACT_IDLE_ELITES
																break;
															default:	// not calm
																return 16;	//Idle_Standing_Pistol			ACT_IDLE_PISTOL
																break;
														}
														break;
													}
												}
												break;
											}
										}
										break;
									}
								}
								break;
							}
						}
						break;
					}
				}
				break;
			}
			default: // is NOT on ground
			{
				switch (sModel_29_Check)
				{
					case 'b': {return 593;	break;}	//Jump_SMG_01			ACT_JUMP_SMG
					case 'd':
					case 'w': {return 606;	break;}	//Jump_DualPistols_01	ACT_JUMP_DUAL_PISTOL
					case 'c': {return 576;	break;}	//Jump_Shotgun_01		ACT_JUMP_SHOTGUN
					case 'h': {return 580;	break;}	//Jump_Shotgun_01		ACT_JUMP_SHOTGUN
					case 'v': {return 488;	break;}	//Jump_Rifle_01			ACT_JUMP_RIFLE
					case 'n': {return 494;	break;}	//Jump_Shotgun_01		ACT_JUMP_SHOTGUN
					case 'e': {return 509;	break;}	//Jump_DualPistols_01	ACT_JUMP_DUAL_PISTOL
					case 'a': {return 506;	break;}	//Jump_DualPistols_01	ACT_JUMP_DUAL_PISTOL
				}
				break;
			}
		}
		return iSequence;
	}
	
	/*function SwapCrouchAnim(client, sequence)
	{
		local sModel_29_Check = NetProps.GetPropString(client, "m_ModelName")[29];
		
		local duckedVar = !!(NetProps.GetPropInt(client, "m_Local.m_bDucked"));
		local duckingVar = !!(NetProps.GetPropInt(client, "m_Local.m_bDucking"));
		
		switch (duckingVar)
		{
			case true:	// is in ducking transition
			{
				switch (duckedVar)
				{
					case true:	// ducking to standing
					{
						
						break;
					}
					default:
					{
						
						break;
					}
				}
				break;
			}
			default:
			{
				
				break;
			}
		}
	}*/
	
	function ShouldHideLegs(client) 
	{
		//printl("thirdpersonshoulder: "+Convars.GetClientConvarValue("c_thirdpersonshoulder", client.GetEntityIndex()));
		local time = Time();
		if (NetProps.GetPropEntity(client, "m_hZoomOwner") == client)
			return true;
		if (NetProps.GetPropEntity(client, "m_hViewEntity") != null)
			return true;
		if (NetProps.GetPropFloat(client, "m_TimeForceExternalView") > time)
			return true;
		if (NetProps.GetPropInt(client, "m_iObserverMode") == 1)
			return true;
		if (NetProps.GetPropInt(client, "m_isIncapacitated") == 1)
			return true;
		if (NetProps.GetPropEntity(client, "m_pummelAttacker") != null)
			return true;
		if (NetProps.GetPropEntity(client, "m_carryAttacker") != null)
			return true;
		if (NetProps.GetPropEntity(client, "m_pounceAttacker") != null)
			return true;
		if (NetProps.GetPropEntity(client, "m_jockeyAttacker") != null)
			return true;
		if (NetProps.GetPropEntity(client, "m_tongueOwner") != null)
			return true;
		if (NetProps.GetPropInt(client, "m_isHangingFromLedge") == 1 || 
		NetProps.GetPropInt(client, "m_isFallingFromLedge") == 1)
			return true;
		if (NetProps.GetPropEntity(client, "m_reviveTarget") != null)
			return true;
		if (NetProps.GetPropFloat(client, "m_staggerTimer.m_timestamp") > time)
			return true;
		switch (NetProps.GetPropInt(client, "m_iCurrentUseAction"))
		{
			case 1:
			{
				local target = NetProps.GetPropEntity(client, "m_useActionTarget");
				
				if (target == NetProps.GetPropEntity(client, "m_useActionOwner"))
					return true;
				else if (target != client)
					return true;
				break;
			}
			case 4: case 5: case 6: case 7: case 8: case 9: case 10: case 11/*holdout*/:
				return true;
		}
		
		local sModel = NetProps.GetPropString(client, "m_ModelName");
		switch (sModel[29])
		{
			case 'b'://nick
			{
				switch (NetProps.GetPropInt(client, "m_nSequence"))
				{
					case 661: // ACT_TERROR_IDLE_FALL_FROM_CHARGERHIT
					case 667: // ACT_TERROR_CHARGERHIT_LAND_SLOW
					case 668: // ACT_TERROR_CHARGER_PUMMELED
					case 671: // ACT_TERROR_SLAMMED_WALL
					case 672: // ACT_TERROR_SLAMMED_GROUND
					case 620: // ACT_TERROR_POUNCED_TO_STAND
					case 680: // ACT_TERROR_REVIVE_FROM_DEATH
					case 630: // ACT_TERROR_TANKPUNCH_LAND
					case 629: // ACT_TERROR_IDLE_FALL_FROM_TANKPUNCH
					case 669: // ACT_TERROR_HIT_BY_CHARGER
					case 628: // ACT_TERROR_HIT_BY_TANKPUNCH
					case 627: // ACT_TERROR_TANKROCK_TO_STAND
					case 605: // ACT_CLIMB_UP
					case 606: // ACT_CLIMB_DOWN
						return true;
				}
				break;
			}
			case 'd': case 'w'://rochelle, adawong
			{
				switch (NetProps.GetPropInt(client, "m_nSequence"))
				{
					case 668: // ACT_TERROR_IDLE_FALL_FROM_CHARGERHIT
					case 674: // ACT_TERROR_CHARGERHIT_LAND_SLOW
					case 675: // ACT_TERROR_CHARGER_PUMMELED
					case 678: // ACT_TERROR_SLAMMED_WALL
					case 679: // ACT_TERROR_SLAMMED_GROUND
					case 629: // ACT_TERROR_POUNCED_TO_STAND
					case 687: // ACT_TERROR_REVIVE_FROM_DEATH
					case 638: // ACT_TERROR_TANKPUNCH_LAND
					case 637: // ACT_TERROR_IDLE_FALL_FROM_TANKPUNCH
					case 676: // ACT_TERROR_HIT_BY_CHARGER
					case 636: // ACT_TERROR_HIT_BY_TANKPUNCH
					case 635: // ACT_TERROR_TANKROCK_TO_STAND
					case 614: // ACT_CLIMB_UP
					case 615: // ACT_CLIMB_DOWN
						return true;
				}
				break;
			}
			case 'c'://coach
			{
				switch (NetProps.GetPropInt(client, "m_nSequence"))
				{
					case 650: // ACT_TERROR_IDLE_FALL_FROM_CHARGERHIT
					case 656: // ACT_TERROR_CHARGERHIT_LAND_SLOW
					case 657: // ACT_TERROR_CHARGER_PUMMELED
					case 660: // ACT_TERROR_SLAMMED_WALL
					case 661: // ACT_TERROR_SLAMMED_GROUND
					case 621: // ACT_TERROR_POUNCED_TO_STAND
					case 669: // ACT_TERROR_REVIVE_FROM_DEATH
					case 630: // ACT_TERROR_TANKPUNCH_LAND
					case 629: // ACT_TERROR_IDLE_FALL_FROM_TANKPUNCH
					case 658: // ACT_TERROR_HIT_BY_CHARGER
					case 628: // ACT_TERROR_HIT_BY_TANKPUNCH
					case 627: // ACT_TERROR_TANKROCK_TO_STAND
					case 606: // ACT_CLIMB_UP
					case 607: // ACT_CLIMB_DOWN
						return true;
				}
				break;
			}
			case 'h'://ellis
			{
				switch (NetProps.GetPropInt(client, "m_nSequence"))
				{
					case 665: // ACT_TERROR_IDLE_FALL_FROM_CHARGERHIT
					case 671: // ACT_TERROR_CHARGERHIT_LAND_SLOW
					case 672: // ACT_TERROR_CHARGER_PUMMELED
					case 675: // ACT_TERROR_SLAMMED_WALL
					case 676: // ACT_TERROR_SLAMMED_GROUND
					case 625: // ACT_TERROR_POUNCED_TO_STAND
					case 684: // ACT_TERROR_REVIVE_FROM_DEATH
					case 635: // ACT_TERROR_TANKPUNCH_LAND
					case 634: // ACT_TERROR_IDLE_FALL_FROM_TANKPUNCH
					case 673: // ACT_TERROR_HIT_BY_CHARGER
					case 633: // ACT_TERROR_HIT_BY_TANKPUNCH
					case 632: // ACT_TERROR_TANKROCK_TO_STAND
					case 610: // ACT_CLIMB_UP
					case 611: // ACT_CLIMB_DOWN
						return true;
				}
				break;
			}
			case 'v'://bill
			{
				switch (NetProps.GetPropInt(client, "m_nSequence"))
				{
					case 753: // ACT_TERROR_IDLE_FALL_FROM_CHARGERHIT
					case 759: // ACT_TERROR_CHARGERHIT_LAND_SLOW
					case 760: // ACT_TERROR_CHARGER_PUMMELED
					case 763: // ACT_TERROR_SLAMMED_WALL
					case 764: // ACT_TERROR_SLAMMED_GROUND
					case 528: // ACT_TERROR_POUNCED_TO_STAND
					case 772: // ACT_TERROR_REVIVE_FROM_DEATH
					case 538: // ACT_TERROR_TANKPUNCH_LAND
					case 537: // ACT_TERROR_IDLE_FALL_FROM_TANKPUNCH
					case 761: // ACT_TERROR_HIT_BY_CHARGER
					case 536: // ACT_TERROR_HIT_BY_TANKPUNCH
					case 535: // ACT_TERROR_TANKROCK_TO_STAND
					case 514: // ACT_CLIMB_UP
					case 515: // ACT_CLIMB_DOWN
						return true;
				}
				break;
			}
			case 'n'://zoey
			{
				switch (NetProps.GetPropInt(client, "m_nSequence"))
				{
					case 813: // ACT_TERROR_IDLE_FALL_FROM_CHARGERHIT
					case 819: // ACT_TERROR_CHARGERHIT_LAND_SLOW
					case 820: // ACT_TERROR_CHARGER_PUMMELED
					case 823: // ACT_TERROR_SLAMMED_WALL
					case 824: // ACT_TERROR_SLAMMED_GROUND
					case 537: // ACT_TERROR_POUNCED_TO_STAND
					case 809: // ACT_TERROR_REVIVE_FROM_DEATH
					case 547: // ACT_TERROR_TANKPUNCH_LAND
					case 546: // ACT_TERROR_IDLE_FALL_FROM_TANKPUNCH
					case 821: // ACT_TERROR_HIT_BY_CHARGER
					case 545: // ACT_TERROR_HIT_BY_TANKPUNCH
					case 544: // ACT_TERROR_TANKROCK_TO_STAND
					case 514: // ACT_CLIMB_UP
					case 515: // ACT_CLIMB_DOWN
						return true;
				}
				break;
			}
			case 'e'://francis
			{
				switch (NetProps.GetPropInt(client, "m_nSequence"))
				{
					case 756: // ACT_TERROR_IDLE_FALL_FROM_CHARGERHIT
					case 762: // ACT_TERROR_CHARGERHIT_LAND_SLOW
					case 763: // ACT_TERROR_CHARGER_PUMMELED
					case 766: // ACT_TERROR_SLAMMED_WALL
					case 767: // ACT_TERROR_SLAMMED_GROUND
					case 531: // ACT_TERROR_POUNCED_TO_STAND
					case 775: // ACT_TERROR_REVIVE_FROM_DEATH
					case 541: // ACT_TERROR_TANKPUNCH_LAND
					case 540: // ACT_TERROR_IDLE_FALL_FROM_TANKPUNCH
					case 764: // ACT_TERROR_HIT_BY_CHARGER
					case 539: // ACT_TERROR_HIT_BY_TANKPUNCH
					case 538: // ACT_TERROR_TANKROCK_TO_STAND
					case 517: // ACT_CLIMB_UP
					case 518: // ACT_CLIMB_DOWN
						return true;
				}
				break;
			}
			case 'a'://louis
			{
				switch (NetProps.GetPropInt(client, "m_nSequence"))
				{
					case 753: // ACT_TERROR_IDLE_FALL_FROM_CHARGERHIT
					case 759: // ACT_TERROR_CHARGERHIT_LAND_SLOW
					case 760: // ACT_TERROR_CHARGER_PUMMELED
					case 763: // ACT_TERROR_SLAMMED_WALL
					case 764: // ACT_TERROR_SLAMMED_GROUND
					case 528: // ACT_TERROR_POUNCED_TO_STAND
					case 772: // ACT_TERROR_REVIVE_FROM_DEATH
					case 538: // ACT_TERROR_TANKPUNCH_LAND
					case 537: // ACT_TERROR_IDLE_FALL_FROM_TANKPUNCH
					case 761: // ACT_TERROR_HIT_BY_CHARGER
					case 536: // ACT_TERROR_HIT_BY_TANKPUNCH
					case 535: // ACT_TERROR_TANKROCK_TO_STAND
					case 514: // ACT_CLIMB_UP
					case 515: // ACT_CLIMB_DOWN
						return true;
				}
				break;
			}
		}
		
		return false;
	}
}

//if (!("survLegs_Init" in this))
//{ survLegs_Init <- null; }

Convars.SetValue("mp_facefronttime", -1);

if (!IsModelPrecached("models/shells/shell_9mm.mdl"))
{ PrecacheModel("models/shells/shell_9mm.mdl"); } // Precache dummy model used by legs' vismodels initially spawning

survivorlegs.ParseConfigFile();

if (!FileToString(info_path))
{
	/*StringToFile(info_path,"THIS IS ONLY AN INFO FILE IN CASE YOU DON'T KNOW WHAT THE SETTINGS DO.\n
	Don't edit this to change the settings.\n
	- LegsOffset[X/Y/Z] (The legs' position on your body will be offset by the amount you set. Big enough values may cause the legs to disappear or flicker.)\n
	- LegsRotation[Pitch/Yaw/Roll] (The legs' rotation on your body will be offset by the amount you set. Due to some tricks being used it is recommended to not touch Pitch.)\n
	- ShowItemsOnLegs (Show your pistols, health items and throwables on your legs. This spawns duplicate unusuable items on your legs to simulate this.)\n
	- RenderLegsOnLowDetail (Allow legs to render on low detail, simulate behavior from L4D1.)\n
	- ILikeMyLegsCalm (Make legs not use calm animations and stand straighter.)\n
	- BreakLegsBecauseImAnIdiot (Hidden setting for testing purposes. Replicates the super-lazy edits of my legs addons.)\n
	\n
	Remove this info file and load a map with the mod updated and enabled, to get the latest info about settings.\n");*/
	StringToFile(info_path,"THIS IS ONLY AN INFO FILE IN CASE YOU DON'T KNOW WHAT THE SETTINGS DO.\nDon't edit this to change the settings.\n- LegsOffset[X/Y/Z] (The legs' position on your body will be offset by the amount you set. Big enough values may cause the legs to disappear or flicker.)\n- LegsRotation[Pitch/Yaw/Roll] (The legs' rotation on your body will be offset by the amount you set. Due to some tricks being used it is recommended to not touch Pitch.)\n- ShowItemsOnLegs (Show your pistols, health items and throwables on your legs. This spawns duplicate unusuable items on your legs to simulate this.)\n- RenderLegsOnLowDetail (Allow legs to render on low detail, simulate behavior from L4D1.)\n- ILikeMyLegsCalm (Make legs not use calm animations and stand straighter.)\n- BreakLegsBecauseImAnIdiot (Hidden setting for testing purposes. Replicates the super-lazy edits of my legs addons.)\n\nRemove this info file and load a map with the mod updated and enabled, to get the latest info about settings.\n");
}

__CollectEventCallbacks(survivorlegs, "OnGameEvent_", "GameEventCallbacks", RegisterScriptGameEventListener)
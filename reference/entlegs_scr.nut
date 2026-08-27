local startingToKill = false;
local isActiveLegs = true;
//local isActiveP = null;

local isInvalidated = false;

local pistolTree =		0;
local grenadeTree =		1;
local aidTree =			2; // Some mods love to put the medkit on the front belt's location
local pillsTree =		3;

if (!("visTree" in this))
{
	visTree <- [
		null,
		null,
		null,
		null,
	]
}

if (!("storedTree" in this))
{
	storedTree <- [
		null,	// Pistol
		null,	// Grenade
		null,	// Medkit
		null,	// Pills
	]
}

if (!("activeTree" in this))
{
	activeTree <- [
		null,	// Pistol
		null,	// Grenade
		null,	// Medkit
		null,	// Pills
	]
}

if (!("modelIdx" in this))
{ modelIdx <- 0; }

function RemoveSelf()
{
	startingToKill = true;
	local parentTarg = self.GetMoveParent();
	if (parentTarg != null && parentTarg.IsValid() && !parentTarg.IsPlayer())
	{
		DoEntFire("!self", "Kill", "", 0.0, null, parentTarg);
	}
	DoEntFire("!self", "Kill", "", 0.0, null, self);
}

local timeCheckVis = 0.0;
local timeCheckArmPose = 0.0;
local timeCheckArmRePing = false;
function LegsThink()
{
	if (startingToKill) return;
	
	if (LegsOwner.IsDead() || LegsOwner.IsDying() || !LegsOwner.IsSurvivor()) { RemoveSelf(); return; }
	
	local function ToggleLegs(boolean)
	{
		switch (boolean)
		{
			case true:
				isActiveLegs = true;
				DoEntFire("!self", "Enable", "", 0.0, null, self);
				foreach (key, val in visTree)
				{
					if (val == null || !val.IsValid()) continue;
					DoEntFire("!self", "Enable", "", 0.0, null, val);
				}
				//if (developer()) printl(LegsOwner+"'s legs are made visible!");
				break;
			default:
				isActiveLegs = false;
				DoEntFire("!self", "Disable", "", 0.0, null, self);
				foreach (key, val in visTree)
				{
					if (val == null || !val.IsValid()) continue;
					DoEntFire("!self", "Disable", "", 0.0, null, val);
				}
				//if (developer()) printl(LegsOwner+"'s legs are made hidden!");
				break;
		}
	}
	local shouldHide = survivorlegs.ShouldHideLegs(LegsOwner);
	if (shouldHide && isActiveLegs)
		ToggleLegs(false);
	else if (!shouldHide && !isActiveLegs)
		ToggleLegs(true);
	
	local newMdlIdx = NetProps.GetPropInt(LegsOwner, "m_nModelIndex");
	if (modelIdx != newMdlIdx)
	{	
		modelIdx = newMdlIdx;
		survivorlegs.AttachLegs(LegsOwner);
	}
	
	if (LegsOwner.GetMoveParent() != null && !isInvalidated)
	{ isInvalidated = true; }
	else if (LegsOwner.GetMoveParent() == null && isInvalidated)
	{
		isInvalidated = false;
		local parentTarg = self.GetMoveParent();
		DoEntFire("!self", "ClearParent", "", 0.0, null, parentTarg);
		DoEntFire("!self", "SetParent", "!activator", 0.01, LegsOwner, parentTarg);
		DoEntFire("!self", "RunScriptCode", "survivorlegs.OffsetLegs(self)", 0.01, null, parentTarg);
		// it seems just firing SetLocalOrigin and/or SetLocalAngles is enough to reset it to proper origin
	}
	
	if (!isActiveLegs) return 0.01;
	
	local playbackRate = NetProps.GetPropFloat(LegsOwner, "m_flPlaybackRate");
	NetProps.SetPropFloat(self, "m_flPlaybackRate", playbackRate);
	//local sequence = survivorlegs.CheckAnimation(LegsOwner);
	NetProps.SetPropInt(self, "m_nSequence", survivorlegs.CheckAnimation(LegsOwner));
	local cycle = NetProps.GetPropFloat(LegsOwner, "m_flCycle");
	NetProps.SetPropFloat(self, "m_flCycle", cycle);
	
	/*if (visTree[pistolTree] != null && visTree[pistolTree].IsValid())
	{
		printl("visTree[pistolTree]'s model: "+NetProps.GetPropString(visTree[pistolTree], "m_ModelName"));
		
	}
	else
	{ printl("visTree[pistolTree] DOES NOT EXIST!");}
	if (visTree[pistolTree] != null && visTree[pistolTree].IsValid())
	{
		printl("storedTree[pistolTree]: "+storedTree[pistolTree]);
	}
	else
	{ printl("storedTree[pistolTree] DOES NOT EXIST!");}*/
	
	local gameTime = Time();
	for (local i = 0; i < 23; i++)
	{
		switch (i)
		{
			case 0: case 2: // body_pitch  head_pitch
				if (timeCheckArmPose <= gameTime)
				{
					if (i == 2)
					{
						timeCheckArmPose = gameTime + 1.0;
						switch (timeCheckArmRePing)
						{
						case true:
							timeCheckArmRePing = false;
							break;
						default:
							timeCheckArmRePing = true;
							break;
						}
					}
					switch (timeCheckArmRePing)
					{
					case true:
						NetProps.SetPropFloatArray(self, "m_flPoseParameter", 0.01, i);
						timeCheckArmRePing = false;
						break;
					default:
						NetProps.SetPropFloatArray(self, "m_flPoseParameter", 0.0, i);
						timeCheckArmRePing = true;
						break;
					}
				}
				break;
			default:
				local paramVal = NetProps.GetPropFloatArray(LegsOwner, "m_flPoseParameter", i);
				NetProps.SetPropFloatArray(self, "m_flPoseParameter", paramVal, i); //credit to death chaos for animating legs
				break;
		}
	}
	
	//local ownerPos = LegsOwner.GetOrigin();
	//local ownerAng = LegsOwner.EyeAngles();
	//local settingsAng = QAngle(90.0 - ownerAng.x, survivorlegs.Settings.LegsRotationYaw, survivorlegs.Settings.LegsRotationRoll);
	
	//local settingsPos = Vector(ownerPos.x, ownerPos.y + 20.0, ownerPos.z); // Parentless system
	//local settingsAng = QAngle(0.0, ownerAng.y, ownerAng.z);
	//printl("ownerAng: "+ownerAng);
	
	//self.SetOrigin(settingsPos);
	//self.SetLocalAngles(settingsAng);
	
	if (!survivorlegs.Settings.ShowItemsOnLegs && timeCheckVis <= gameTime)
	{
		timeCheckVis = gameTime + 5.0;
		for (local treeNum = pistolTree; treeNum <= pillsTree; treeNum++)
		{
			if (visTree[treeNum] == null || !visTree[treeNum].IsValid()) continue;
			ToggleVis(false, treeNum, true);
		}
		return;
	}
	
	if (timeCheckVis <= gameTime)
	{
		local function CheckActive(treeNum = 0)
		{
			local activeWep = LegsOwner.GetActiveWeapon();
			switch (activeTree[treeNum])
			{
				case true:
					if (activeWep == storedTree[treeNum]) { ToggleVis(false, treeNum);	/*if (developer()) printl(LegsOwner+"'s legs: Pistol toggled OFF");*/ }
					break;
				default:
					if (activeWep != storedTree[treeNum]) { ToggleVis(true, treeNum);	/*if (developer()) printl(LegsOwner+"'s legs: Pistol toggled ON");*/ }
					break;
			}
		}
		
		local invTable = {};
		GetInvTable(LegsOwner, invTable);
		//g_ModeScript.DeepPrintTable(invTable);
		for (local treeNum = pistolTree; treeNum <= pillsTree; treeNum++) // Put it in a loop
		{
			if (storedTree[treeNum] != null && storedTree[treeNum].IsValid() && NetProps.HasProp(storedTree[treeNum], "m_hOwnerEntity") && 
				NetProps.GetPropEntity(storedTree[treeNum], "m_hOwnerEntity") == LegsOwner)
			{
				CheckActive(treeNum);
			}
			else
			{
				timeCheckVis = gameTime + 0.25;
				
				local slotLoc = null;
				switch (treeNum) // Select the slots
				{
					case pistolTree: // v Pistol
						if (("slot1" in invTable) && invTable.slot1 != null && invTable.slot1.IsValid()) slotLoc = invTable.slot1;
						break;
					case grenadeTree: // v Grenade
						if (("slot2" in invTable) && invTable.slot2 != null && invTable.slot2.IsValid()) slotLoc = invTable.slot2;
						break;
					case aidTree: // v FirstAid
						if (("slot3" in invTable) && invTable.slot3 != null && invTable.slot3.IsValid()) slotLoc = invTable.slot3;
						break;
					case pillsTree: // v Pills
						if (("slot4" in invTable) && invTable.slot4 != null && invTable.slot4.IsValid()) slotLoc = invTable.slot4;
						break;
				}
				if (slotLoc != null)
				{
					//if (developer()) printl(LegsOwner+"'s legs: item of tree slot "+treeNum+" found. "+slotLoc);
					
					// TODO: can the system be moved to m_iWorldModelIndex for better optimization and flexibility?
					/*if (NetProps.HasProp(slotLoc, "m_iWorldModelIndex"))
					{
						if (visTree[treeNum] != null && visTree[treeNum].IsValid())
						{
							local wMIdx = NetProps.GetPropInt(slotLoc, "m_iWorldModelIndex");
							local wMIdxVis = NetProps.GetPropInt(visTree[treeNum], "m_nModelIndex");
							//printl("wMIdx: "+wMIdx+" | wMIdxVis: "+wMIdxVis);
							if (wMIdx == wMIdxVis)
							{ continue; }
						}
					}*/
					// ^ this check has been nothing but a fucking headache
					// in the entire lifespan of the mod
					// it conflicts with same items being picked up, like picking up a Molotov just after you throw another Molotov
					// and always fucking bugs out one way or another
					
					local className = slotLoc.GetClassname();
					// temp check, replace with GetModelVis when I finally figure out to detect melee models dynamically
					if (treeNum == pistolTree && (7 in className) && className[7] != 'p') // Detect if not pistol
					{
						ToggleVis(false, treeNum, true);
						continue;
					}
					local visArr = GetModelVis(treeNum, className);
					if (visArr == null) continue;
					
					if (visTree[treeNum] == null || !visTree[treeNum].IsValid()) { SpawnVis(treeNum); }
					
					storedTree[treeNum] = slotLoc; // Store it
					CheckActive(treeNum);
					
					ReattachVis(visTree[treeNum], visArr);
				}
				else
				{
					// If a slot doesn't exist there, kill the vis
					ToggleVis(false, treeNum, true);
				}
			}
		}
		invTable.clear();
	}
	return 0.01;
}

function ToggleVis(boolean, treeNum = 0, destroy = false)
{
	switch (boolean)
	{
		case true:
			//if (visTree[treeNum] == null || !visTree[treeNum].IsValid()) { SpawnVis(treeNum); } // Attempt to spawn
			if (visTree[treeNum] == null || !visTree[treeNum].IsValid()) break;
			
			DoEntFire("!self", "Enable", "", 0.0, null, visTree[treeNum]);
			activeTree[treeNum] = true;
			break;
		default:
			if (visTree[treeNum] == null || !visTree[treeNum].IsValid()) break;
			
			DoEntFire("!self", "Disable", "", 0.0, null, visTree[treeNum]);
			if (destroy)
			{
				DoEntFire("!self", "Kill", "", 0.0, null, visTree[treeNum]);
				storedTree[treeNum] = null;
			}
			activeTree[treeNum] = false;
			break;
	}
}

function SpawnVis(treeNum)
{
	local holsTbl = {
		origin = self.GetOrigin().ToKVString(),
		model = "models/shells/shell_9mm.mdl", // dummy model
		solid = 0,
		spawnflags = 128 | 256,
		effects = (1 << 4) + (1 << 6) + (1 << 11) + (1 << 13),	// EF_NOSHADOW | EF_NORECEIVESHADOW | EF_NOSHADOWDEPTH | EF_NOFLASHLIGHT
		fademindist = 1,
		fademaxdist = 1 // seems like just setting these to 1 is enough, unlike the legs
	};
	holsTbl.mincpulevel <- NetProps.GetPropInt(self, "m_nMinCPULevel");
	holsTbl.maxcpulevel <- NetProps.GetPropInt(self, "m_nMaxCPULevel");
	local holsterEnt = SpawnEntityFromTable("prop_dynamic_override", holsTbl);
	if (holsterEnt == null || !holsterEnt.IsValid()) return;
	visTree[treeNum] = holsterEnt;
	
	DoEntFire("!self", "SetParent", "!activator", 0.0, self, holsterEnt); // Parent the vis to the legs
	
	NetProps.SetPropInt(holsterEnt, "movetype", 0); // MOVETYPE_NONE
	NetProps.SetPropInt(holsterEnt, "m_MoveType", 0);
	
	local iEFlags = NetProps.GetPropInt(holsterEnt, "m_iEFlags");
	iEFlags = iEFlags | (1<<25); // EFL_DONTBLOCKLOS
	NetProps.SetPropInt(holsterEnt, "m_iEFlags", iEFlags);
	
	NetProps.SetPropInt(holsterEnt, "m_bClientSideAnimation", 1);
	NetProps.SetPropInt(holsterEnt, "m_noGhostCollision", 1);
	NetProps.SetPropInt(holsterEnt, "m_bClientPhysics", 0);
	
	switch (activeTree[treeNum])
	{
		case true: ToggleVis(true, treeNum); break;
		default: ToggleVis(false, treeNum); break;
	}
}

function GetModelVis(treeNum, className) // [model, attachment, offsetOrigin, offsetAngles]
{
	if (!(7 in className)) return null;
	
	switch (treeNum) // Then we switch code up
	{
		case pistolTree: 
			if (className[7] != 'p') // Detect if not pistol
			{ return null; }
			
			// v Melee
			//	storedTree[treeNum] = slotLoc;
			//	CheckActive(treeNum);
			//	
			//	if (visTree[treeNum] == null || !visTree[treeNum].IsValid()) break;
			//	
			//	//DoEntFire("!self", "SetParentAttachment", "melee", 0.0, null, visTree[treeNum]);
			//	DoEntFire("!self", "SetParentAttachment", "pistol", 0.0, null, visTree[treeNum]);
			//	
			//	local testStr = NetProps.GetPropString(slotLoc, "m_ModelName");
			//	printl("Melee info\nm_ModelName: "+NetProps.GetPropString(slotLoc, "m_ModelName")+
			//	"\nm_iWorldModelIndex: "+NetProps.GetPropInt(slotLoc, "m_iWorldModelIndex"));
			//	printl("m_ModelName's index: "+GetModelIndex(testStr)+"\nm_nModelIndex: "+NetProps.GetPropInt(slotLoc, "m_nModelIndex"));
			//	
			//	NetProps.SetPropInt(visTree[treeNum], "m_iWorldModelIndex", NetProps.GetPropInt(slotLoc, "m_iWorldModelIndex"));
			
			else // Otherwise if not melee
			{
				// v Pistol
				local isMagnum = (19 in className); // Detect the letter size of weapon_pistol_magnum, use the last M
				if (19 in className)
				{ return ["models/w_models/weapons/w_desert_eagle.mdl", "pistol", Vector(0,0,-2)]; }
				// Offset the magnum to the best of what I can see on the legs.
				else
				{ return ["models/w_models/weapons/w_pistol_a.mdl", "pistol"]; }
			}
			break;
		case grenadeTree: // v Grenade
			switch (className[7])
			{
				case 'v':	// Detect weapon_vomitjar
					return ["models/w_models/weapons/w_eq_bile_flask.mdl", "molotov"];
					break;
				case 'p':	// Detect weapon_pipebomb
					return ["models/w_models/weapons/w_eq_pipebomb.mdl", "molotov"];
					break;
				//case 'm':
				default:	// Detect weapon_molotov
					return ["models/w_models/weapons/w_eq_molotov.mdl", "molotov"];
					break;
			}
			break;
		case aidTree: // v FirstAid
			if (27 in className) // Check if they're upgrades
			{
				if (className[19] == 'e') // Detect weapon_upgradepack_explosive
				{ return ["models/w_models/weapons/w_eq_explosive_ammopack.mdl", "medkit"]; }
				else //if (19 in className && className[19] == 'i') // Detect weapon_upgradepack_incendiary
				{ return ["models/w_models/weapons/w_eq_incendiary_ammopack.mdl", "medkit"]; }
			}
			else if (className[7] == 'd') // Detect weapon_defibrillator
			{ return ["models/w_models/weapons/w_eq_defibrillator.mdl", "medkit", Vector(1,0,0), QAngle(-90,10,6)]; }
			else //if (className[7] == 'f') // Detect weapon_first_aid_kit
			{ return ["models/w_models/weapons/w_eq_medkit.mdl", "medkit", Vector(0,0,-3)]; }
			break;
		case pillsTree: // v Pills
			if (className[7] == 'a') // Detect weapon_adrenaline
			{ return ["models/w_models/weapons/w_eq_adrenaline.mdl", "pills", Vector(-0.45,0.05,0), QAngle(-15,30,280)]; }
			else
			{ return ["models/w_models/weapons/w_eq_painpills.mdl", "pills"]; }
			break;
	}
	return null;
}

function ReattachVis(visMdl, visArr)
{
	visMdl.SetModel(visArr[0]);
	DoEntFire("!self", "SetParentAttachment", visArr[1], 0.0, null, visMdl);
	if (2 in visArr)
	{
		local visVec = visArr[2];
		DoEntFire("!self", "RunScriptCode", "self.SetLocalOrigin(Vector("+visVec.x+","+visVec.y+","+visVec.z+"))", 0.0, null, visMdl);
	}
	if (3 in visArr)
	{
		local visAng = visArr[3];
		DoEntFire("!self", "RunScriptCode", "self.SetLocalAngles(QAngle("+visAng.x+","+visAng.y+","+visAng.z+"))", 0.0, null, visMdl);
	}
}
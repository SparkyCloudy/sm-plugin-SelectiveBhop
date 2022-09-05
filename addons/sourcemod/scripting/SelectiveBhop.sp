#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <PhysHooks>
#include <SelectiveBhop>
#include <multicolors>
#tryinclude <zombiereloaded>



ConVar g_CVar_sv_enablebunnyhopping;
#if defined _zr_included
float g_fZombieVelocity;
float g_fHumanVelocity;
bool g_bBhopVelocity;

ConVar g_CVar_zr_disablebunnyhopping;
ConVar g_CVar_zr_bhopvelocity;
ConVar gCV_ZombieVelocity;
ConVar gCV_HumanVelocity;
#endif

enum
{
	LIMITED_NONE = 0,
	LIMITED_GENERAL = 1,

	// Temp
	LIMITED_ZOMBIE = 2
}

bool g_bEnabled = false;
#if defined _zr_included
bool g_bZombieEnabled = false;
#endif
bool g_bInOnPlayerRunCmd = false;

int g_ClientLimited[MAXPLAYERS + 1] = {LIMITED_NONE, ...};
int g_ActiveLimitedFlags = LIMITED_GENERAL;

StringMap g_ClientLimitedCache;

public Plugin myinfo =
{
	name = "Selective Bunnyhop",
	author = "BotoX + .Rushaway + Sparky",
	description = "Disables bunnyhop on certain players/groups or Limited velocity bunnyhop on certain groups",
	version = "0.4"
}

public void OnPluginStart()
{

	LoadTranslations("common.phrases");

	g_CVar_sv_enablebunnyhopping = FindConVar("sv_enablebunnyhopping");
	g_CVar_sv_enablebunnyhopping.Flags &= ~FCVAR_REPLICATED;
	g_CVar_sv_enablebunnyhopping.AddChangeHook(OnConVarChanged);
	g_bEnabled = g_CVar_sv_enablebunnyhopping.BoolValue;

#if defined _zr_included
	HookEvent("player_jump", OnPlayerJump);

	g_CVar_zr_bhopvelocity = CreateConVar("zr_bhopvelocity_enable", "1", "Enable or Disable the plugin.", _, true, 0.0, true, 1.0);
	g_bBhopVelocity = g_CVar_zr_bhopvelocity.BoolValue;

	g_CVar_zr_disablebunnyhopping = CreateConVar("zr_disablebunnyhopping", "0", "Disable bhop for zombies.", FCVAR_NOTIFY);
	g_bZombieEnabled = g_CVar_zr_disablebunnyhopping.BoolValue;

	gCV_ZombieVelocity = CreateConVar("zr_bhopvelocity_zombies", "300", "Maximum zombies velocity to keep per jump. (min. 300)", _, true, 300.0);
	gCV_HumanVelocity = CreateConVar("zr_bhopvelocity_humans", "300", "Maximum humans velocity to keep per jump. (min. 300)", _, true, 300.0);

	g_CVar_zr_bhopvelocity.AddChangeHook(OnConVarChanged);
	g_CVar_zr_disablebunnyhopping.AddChangeHook(OnConVarChanged);
	gCV_ZombieVelocity.AddChangeHook(OnConVarChanged);
	gCV_HumanVelocity.AddChangeHook(OnConVarChanged);

	AutoExecConfig();
#endif

	g_ClientLimitedCache = new StringMap();

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	RegAdminCmd("sm_bhop", Command_Bhop, ADMFLAG_GENERIC, "sm_bhop <#userid|name> <0|1>");

	RegConsoleCmd("sm_bhopstatus", Command_Status, "sm_bhopstatus [#userid|name]");

	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i) || IsFakeClient(i))
			continue;

#if defined _zr_included
		if(ZR_IsClientZombie(i))
			AddLimitedFlag(i, LIMITED_ZOMBIE);
#endif
	}

	UpdateLimitedFlags();
	UpdateClients();
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{

	CreateNative("LimitBhop", Native_LimitBhop);
	CreateNative("IsBhopLimited", Native_IsBhopLimited);
	RegPluginLibrary("SelectiveBhop");

	return APLRes_Success;
}

public void OnPluginEnd()
{
	g_CVar_sv_enablebunnyhopping.BoolValue = g_bEnabled;
	g_CVar_sv_enablebunnyhopping.Flags |= FCVAR_REPLICATED|FCVAR_NOTIFY;

	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && !IsFakeClient(i))
		{
			if(g_CVar_sv_enablebunnyhopping.BoolValue)
				g_CVar_sv_enablebunnyhopping.ReplicateToClient(i, "1");
			else
				g_CVar_sv_enablebunnyhopping.ReplicateToClient(i, "0");
		}
	}
}

public void OnMapEnd()
{
	g_ClientLimitedCache.Clear();
}

public void OnClientPutInServer(int client)
{
	TransmitConVar(client);
}

public void OnClientDisconnect(int client)
{
	int LimitedFlag = g_ClientLimited[client] & ~(LIMITED_ZOMBIE);

	if(LimitedFlag != LIMITED_NONE)
	{
		char sSteamID[64];
		if(GetClientAuthId(client, AuthId_Engine, sSteamID, sizeof(sSteamID)))
			g_ClientLimitedCache.SetValue(sSteamID, LimitedFlag, true);
	}

	g_ClientLimited[client] = LIMITED_NONE;
}

public void OnClientPostAdminCheck(int client)
{
	char sSteamID[64];
	if(GetClientAuthId(client, AuthId_Engine, sSteamID, sizeof(sSteamID)))
	{
		int LimitedFlag;
		if(g_ClientLimitedCache.GetValue(sSteamID, LimitedFlag))
		{
			AddLimitedFlag(client, LimitedFlag);
			g_ClientLimitedCache.Remove(sSteamID);
		}
	}
}

public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if(convar == g_CVar_sv_enablebunnyhopping)
	{
		if(g_bInOnPlayerRunCmd)
			return;

		g_bEnabled = convar.BoolValue;
		UpdateClients();
	}
#if defined _zr_included
	else if(convar == g_CVar_zr_disablebunnyhopping)
	{
		g_bZombieEnabled = convar.BoolValue;
		UpdateLimitedFlags();
	}
	g_bBhopVelocity = g_CVar_zr_bhopvelocity.BoolValue;
	g_fZombieVelocity = gCV_ZombieVelocity.FloatValue;
	g_fHumanVelocity = gCV_HumanVelocity.FloatValue;
#endif
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if(!g_bEnabled)
		return Plugin_Continue;

	bool bEnableBunnyhopping = !(g_ClientLimited[client] & g_ActiveLimitedFlags);
	if(bEnableBunnyhopping == g_CVar_sv_enablebunnyhopping.BoolValue)
		return Plugin_Continue;

	if(!g_bInOnPlayerRunCmd)
	{
		g_CVar_sv_enablebunnyhopping.Flags &= ~FCVAR_NOTIFY;
		g_bInOnPlayerRunCmd = true;
	}

	g_CVar_sv_enablebunnyhopping.BoolValue = bEnableBunnyhopping;

	return Plugin_Continue;
}

public void OnRunThinkFunctionsPost(bool simulating)
{
	if(g_bInOnPlayerRunCmd)
	{
		g_CVar_sv_enablebunnyhopping.BoolValue = g_bEnabled;
		g_CVar_sv_enablebunnyhopping.Flags |= FCVAR_NOTIFY;
		g_bInOnPlayerRunCmd = false;
	}
}

public void ZR_OnClientInfected(int client, int attacker, bool motherInfect, bool respawnOverride, bool respawn)
{
	AddLimitedFlag(client, LIMITED_ZOMBIE);
}

public void ZR_OnClientHumanPost(int client, bool respawn, bool protect)
{
	RemoveLimitedFlag(client, LIMITED_ZOMBIE);
}

#if defined _zr_included
public void ZR_OnClientRespawned(int client, ZR_RespawnCondition condition)
{
	if(condition == ZR_Respawn_Human)
		RemoveLimitedFlag(client, LIMITED_ZOMBIE);
	else
		AddLimitedFlag(client, LIMITED_ZOMBIE);
}

public void OnPlayerJump(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	
	if(!g_bBhopVelocity)
	{
		return;
	}
	else
	{
		RequestFrame(MaxBhopClient, client);
	}
}
#endif

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	RemoveLimitedFlag(-1, LIMITED_ZOMBIE);
}

void UpdateLimitedFlags()
{
	int Flags = LIMITED_GENERAL;

#if defined _zr_included
	if(g_bZombieEnabled)
		Flags |= LIMITED_ZOMBIE;
#endif

	if(g_ActiveLimitedFlags != Flags)
	{
		g_ActiveLimitedFlags = Flags;
		UpdateClients();
	}
	g_ActiveLimitedFlags = Flags;
}

stock void AddLimitedFlag(int client, int Flag)
{
	if(client == -1)
	{
		for(int i = 1; i <= MaxClients; i++)
			_AddLimitedFlag(i, Flag);
	}
	else
		_AddLimitedFlag(client, Flag);
}

stock void _AddLimitedFlag(int client, int Flag)
{
	bool bWasLimited = view_as<bool>(g_ClientLimited[client] & g_ActiveLimitedFlags);
	g_ClientLimited[client] |= Flag;
	bool bIsLimited = view_as<bool>(g_ClientLimited[client] & g_ActiveLimitedFlags);

	if(bIsLimited != bWasLimited)
		TransmitConVar(client);
}

stock void RemoveLimitedFlag(int client, int Flag)
{
	if(client == -1)
	{
		for(int i = 1; i <= MaxClients; i++)
			_RemoveLimitedFlag(i, Flag);
	}
	else
		_RemoveLimitedFlag(client, Flag);
}

stock void _RemoveLimitedFlag(int client, int Flag)
{
	bool bWasLimited = view_as<bool>(g_ClientLimited[client] & g_ActiveLimitedFlags);
	g_ClientLimited[client] &= ~Flag;
	bool bIsLimited = view_as<bool>(g_ClientLimited[client] & g_ActiveLimitedFlags);

	if(bIsLimited != bWasLimited)
		TransmitConVar(client);
}

stock void UpdateClients()
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i))
			TransmitConVar(i);
	}
}

stock void TransmitConVar(int client)
{
	if(!IsClientInGame(client) || IsFakeClient(client))
		return;

	bool bIsLimited = view_as<bool>(g_ClientLimited[client] & g_ActiveLimitedFlags);

	if(g_bEnabled && !bIsLimited)
		g_CVar_sv_enablebunnyhopping.ReplicateToClient(client, "1");
	else
		g_CVar_sv_enablebunnyhopping.ReplicateToClient(client, "0");
}

public Action Command_Bhop(int client, int argc)
{
	if (!client)
	{
		PrintToServer("[SM] Cannot use command from server console.");
		return Plugin_Handled;
	}

	if(argc < 2)
	{
		ReplyToCommand(client, "[SM] Usage: sm_bhop <#userid|name> <0|1>");
		return Plugin_Handled;
	}

	char sArg[64];
	char sArg2[2];
	char sTargetName[MAX_TARGET_LENGTH];
	int iTargets[MAXPLAYERS];
	int iTargetCount;
	bool bIsML;
	bool bValue;

	GetCmdArg(1, sArg, sizeof(sArg));
	GetCmdArg(2, sArg2, sizeof(sArg2));

	bValue = sArg2[0] == '1' ? true : false;

	if((iTargetCount = ProcessTargetString(sArg, client, iTargets, MAXPLAYERS, COMMAND_FILTER_NO_MULTI, sTargetName, sizeof(sTargetName), bIsML)) <= 0)
	{
		ReplyToTargetError(client, iTargetCount);
		return Plugin_Handled;
	}

	for(int i = 0; i < iTargetCount; i++)
	{
		if(bValue)
			RemoveLimitedFlag(iTargets[i], LIMITED_GENERAL);
		else
			AddLimitedFlag(iTargets[i], LIMITED_GENERAL);
	}

	ShowActivity2(client, "[SM] {olive}", "{default}Bunnyhop on target {olive}%s {default}has been %s", sTargetName, bValue ? "{green}Un-Restricted" : "{red}Limited");

	if(iTargetCount > 1)
		LogAction(client, -1, "\"%L\" %s bunnyhop on target \"%s\"", client, bValue ? "{green}Un-Restricted" : "{red}Limited", sTargetName);
	else
		LogAction(client, iTargets[0], "\"%L\" %s bunnyhop on target \"%L\"", client, bValue ? "{green}Un-Restricted" : "{red}Limited", iTargets[0]);

	return Plugin_Handled;
}

public Action Command_Status(int client, int argc)
{
	if (!client)
	{
		CPrintToServer("[SM] Cannot use command from server console.");
		return Plugin_Handled;
	}

	if (argc && CheckCommandAccess(client, "", ADMFLAG_BAN, true))
	{
		char sArgument[64];
		GetCmdArg(1, sArgument, sizeof(sArgument));

		int target = -1;
		if((target = FindTarget(client, sArgument, true, false)) == -1)
			return Plugin_Handled;

		if(IsBhopLimited(target))
		{
			ReplyToCommand(client, "[SM] {olive}%N {default}bhop is currently : {red}Limited", target);
			return Plugin_Handled;
		}
		else
		{
			ReplyToCommand(client, "[SM] {olive}%N {default}bhop is currently : {green}Not Restricted", target);
			return Plugin_Handled;
		}
	}
	else
	{
		if(IsBhopLimited(client))
		{
			ReplyToCommand(client, "[SM] Your bhop is currently : {red}Limited");
			return Plugin_Handled;
		}
		else
		{
			ReplyToCommand(client, "[SM] Your bhop is currently : {green}Not restricted");
			return Plugin_Handled;
		}
	}
}

public int Native_LimitBhop(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	bool bLimited = view_as<bool>(GetNativeCell(2));

	if(client > MaxClients || client <= 0)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Client is not valid.");
		return -1;
	}

	if(!IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Client is not in-game.");
		return -1;
	}

	if(bLimited)
		AddLimitedFlag(client, LIMITED_GENERAL);
	else
		RemoveLimitedFlag(client, LIMITED_GENERAL);

	return 0;
}

public int Native_IsBhopLimited(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);

	if(client > MaxClients || client <= 0)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Client is not valid.");
		return -1;
	}

	if(!IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Client is not in-game.");
		return -1;
	}

	int LimitedFlag = g_ClientLimited[client] & ~(LIMITED_ZOMBIE);

	return LimitedFlag != LIMITED_NONE;
}

#if defined _zr_included
void MaxBhopClient(int client)
{
	if(ZR_IsClientZombie(client) && IsClientInGame(client))
	{
		float fZombieAbsVelocity[3];
		GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", fZombieAbsVelocity);
		
		float fZombieCurrentSpeed = SquareRoot(Pow(fZombieAbsVelocity[0], 2.0) + Pow(fZombieAbsVelocity[1], 2.0));
		
		if(fZombieCurrentSpeed > 0.0)
		{
			float fZombieMax = g_fZombieVelocity;
			
			if(fZombieCurrentSpeed > fZombieMax)
			{
				float x = fZombieCurrentSpeed / fZombieMax;
				fZombieAbsVelocity[0] /= x;
				fZombieAbsVelocity[1] /= x;
				
				TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, fZombieAbsVelocity);
			}
		}
	}
	
	if(ZR_IsClientHuman(client) && IsClientInGame(client))
	{
		float fHumanAbsVelocity[3];
		GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", fHumanAbsVelocity);
		
		float fHumanCurrentSpeed = SquareRoot(Pow(fHumanAbsVelocity[0], 2.0) + Pow(fHumanAbsVelocity[1], 2.0));
		
		if(fHumanCurrentSpeed > 0.0)
		{
			float fHumanMax = g_fHumanVelocity;
			
			if(fHumanCurrentSpeed > fHumanMax)
			{
				float x = fHumanCurrentSpeed / fHumanMax;
				fHumanAbsVelocity[0] /= x;
				fHumanAbsVelocity[1] /= x;
				
				TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, fHumanAbsVelocity);
			}
		}
	}
}
#endif

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

// Usando o SEU arquivo .inc (Custom_YesNo = 3, YES = 1)
#undef REQUIRE_PLUGIN
#include <builtinvotes>

#define TEAM_SPECTATE 1
#define EMPTY_SERVER_RESET_DELAY 60.0

Handle g_hVote = null;
float g_fLastVoteTime[MAXPLAYERS + 1];
StringMap g_hDeniedThisMap = null;
char g_sCurrentVoteStarter[64];
int g_iPendingTickrate = 0;
Database g_hTickrateDb = null;
ConVar g_hHostname = null;
bool g_bHadHumanPlayers = false;
Handle g_hEmptyResetTimer = null;

ConVar g_hCvarCooldown = null;
ConVar g_hCvarPlayerLimit = null;
ConVar g_hCvarDedicatedServ = null;
ConVar g_hCvarAnnounceEnable = null;
ConVar g_hCvarAnnounceInterval = null;
ConVar g_hGameMode = null;
ConVar g_hTickDoorSpeed = null;
ConVar g_hPistolDelayDualies = null;
ConVar g_hPistolDelaySingle = null;
ConVar g_hPistolDelayIncapped = null;
ConVar g_hFpsMax = null;

bool g_bHookedTickDoorSpeed = false;
bool g_bHookedPistolDelayDualies = false;
bool g_bHookedPistolDelaySingle = false;
bool g_bHookedPistolDelayIncapped = false;
bool g_bHookedFpsMax = false;

bool g_bApplyingManagedCvars = false;
bool g_bHasManagedCvarProfile = false;
float g_fManagedDoorSpeed = 1.0;
float g_fManagedDualiesDelay = 0.1;
float g_fManagedSingleDelay = 0.2;
float g_fManagedIncappedDelay = 0.3;
int g_iManagedFpsMax = 40;
bool g_bManagedFpsEnabled = false;
Handle g_hAnnounceTimer = null;

public Plugin myinfo = 
{
    name = "Kick Bots (ZoneMod Style) V2.1",
    author = "AI Friend",
    description = "Simula sucesso imediato se estiver solo",
    version = "2.1",
    url = ""
};

public void OnPluginStart()
{
    RegConsoleCmd("sm_kickbots", Command_KickBots);
    RegConsoleCmd("sm_tickrate", Command_Tickrate);
    RegAdminCmd("sm_kab_dedicateserv", Command_KabDedicatedServ, ADMFLAG_GENERIC, "sm_kab_dedicateserv <0|1> - 0 desativa ajuste de fps_max por tickrate, 1 ativa");
    
    g_hCvarCooldown = CreateConVar("sm_kickbots_cooldown", "30.0", "Tempo de espera", FCVAR_NOTIFY);
    g_hCvarDedicatedServ = CreateConVar("sm_kab_dedicateserv_mode", "0", "0 desativa ajuste de fps_max por tickrate, 1 ativa", FCVAR_NOTIFY);
    g_hCvarDedicatedServ.AddChangeHook(OnDedicatedServModeChanged);
    g_hCvarAnnounceEnable = CreateConVar("sm_kab_announce_enable", "1", "0 desativa mensagens automaticas dos comandos KAB, 1 ativa", FCVAR_NOTIFY);
    g_hCvarAnnounceInterval = CreateConVar("sm_kab_announce_interval", "180.0", "Intervalo em segundos das mensagens automaticas KAB", FCVAR_NOTIFY);
    g_hCvarAnnounceEnable.AddChangeHook(OnAnnounceSettingsChanged);
    g_hCvarAnnounceInterval.AddChangeHook(OnAnnounceSettingsChanged);
    g_hDeniedThisMap = new StringMap();
    g_hGameMode = FindConVar("mp_gamemode");
    g_hHostname = FindConVar("hostname");

    InitTickrateDatabase();
    g_bHadHumanPlayers = (GetHumanPlayerCount() > 0);
    if (g_bHadHumanPlayers)
    {
        ApplySavedTickrateForCurrentServer();
    }
    else
    {
        SaveTickrateForCurrentServer(30);
        TrySetTickrateConVar(30);
    }
    g_hCvarPlayerLimit = CreateConVar("sm_kickbots_player_limit", "1", "Mínimo de players", FCVAR_NOTIFY);
    SetupAnnouncementTimer();
}

public void OnMapStart()
{
    if (g_hDeniedThisMap != null)
    {
        g_hDeniedThisMap.Clear();
    }
}

public void OnConfigsExecuted()
{
    ApplySavedTickrateForCurrentServer();
    SetupAnnouncementTimer();
}

public void OnAnnounceSettingsChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    SetupAnnouncementTimer();
}

void SetupAnnouncementTimer()
{
    if (g_hAnnounceTimer != null)
    {
        delete g_hAnnounceTimer;
        g_hAnnounceTimer = null;
    }

    if (g_hCvarAnnounceEnable == null || !g_hCvarAnnounceEnable.BoolValue)
    {
        return;
    }

    float fInterval = 180.0;
    if (g_hCvarAnnounceInterval != null)
    {
        fInterval = g_hCvarAnnounceInterval.FloatValue;
    }

    if (fInterval < 30.0)
    {
        fInterval = 30.0;
    }

    g_hAnnounceTimer = CreateTimer(fInterval, Timer_AnnounceCommands, _, TIMER_REPEAT);
}

public Action Timer_AnnounceCommands(Handle timer)
{
    if (GetHumanPlayerCount() <= 0)
    {
        return Plugin_Continue;
    }

    if (IsVersusLikeMode())
    {
        PrintToChatAll("[\x04KAB\x01] Dica: use \x05!tickrate\x01 para votar mudanca de tickrate e reiniciar o mapa.");
    }
    else
    {
        PrintToChatAll("[\x04KAB\x01] Comandos: \x05!kickbots\x01 (remove bots por voto) e \x05!tickrate\x01 (muda tickrate por voto).");
    }

    return Plugin_Continue;
}

public void OnClientPutInServer(int client)
{
    if (client <= 0 || IsFakeClient(client))
    {
        return;
    }

    if (g_hEmptyResetTimer != null)
    {
        delete g_hEmptyResetTimer;
        g_hEmptyResetTimer = null;
    }

    if (!g_bHadHumanPlayers)
    {
        g_bHadHumanPlayers = true;
        SaveTickrateForCurrentServer(30);
        TrySetTickrateConVar(30);
    }
}

public void OnClientDisconnect_Post(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    if (GetHumanPlayerCount() == 0)
    {
        if (g_hEmptyResetTimer == null)
        {
            g_hEmptyResetTimer = CreateTimer(EMPTY_SERVER_RESET_DELAY, Timer_ResetTickrateIfStillEmpty);
        }
    }
}

public Action Command_KabDedicatedServ(int client, int args)
{
    if (args < 1)
    {
        int iCurrentMode = 0;
        if (g_hCvarDedicatedServ != null)
        {
            iCurrentMode = g_hCvarDedicatedServ.IntValue;
        }

        ReplyToCommand(client, "[KAB] Use: sm_kab_dedicateserv <0|1>. Atual: %d", iCurrentMode);
        return Plugin_Handled;
    }

    char sMode[8];
    GetCmdArg(1, sMode, sizeof(sMode));

    int iMode = StringToInt(sMode);
    if (iMode != 0 && iMode != 1)
    {
        ReplyToCommand(client, "[KAB] Valor invalido. Use 0 ou 1.");
        return Plugin_Handled;
    }

    if (g_hCvarDedicatedServ != null)
    {
        g_hCvarDedicatedServ.IntValue = iMode;
    }

    ReplyToCommand(client, "[KAB] sm_kab_dedicateserv = %d", iMode);
    ApplySavedTickrateForCurrentServer();
    return Plugin_Handled;
}

public Action Command_KickBots(int client, int args)
{
    if (client == 0) return Plugin_Handled;

    if (IsClientDeniedThisMap(client))
    {
        PrintToChat(client, "[\x04Vote\x01] Seu ultimo voto de kick bots foi recusado. Aguarde o proximo mapa.");
        return Plugin_Handled;
    }

    float fCooldown = g_hCvarCooldown.FloatValue;
    float fCurrentTime = GetEngineTime();
    if (fCurrentTime - g_fLastVoteTime[client] < fCooldown)
    {
        int iWait = RoundToNearest(fCooldown - (fCurrentTime - g_fLastVoteTime[client]));
        PrintToChat(client, "[\x04Vote\x01] Aguarde %d segundos.", iWait);
        return Plugin_Handled;
    }

    if (StartKickBotsVote(client))
    {
        g_fLastVoteTime[client] = fCurrentTime;
    }

    return Plugin_Handled;
}

public Action Command_Tickrate(int client, int args)
{
    if (client == 0) return Plugin_Handled;

    if (GetClientTeam(client) <= TEAM_SPECTATE)
    {
        PrintToChat(client, "[\x04Tickrate\x01] Espectadores nao iniciam votacao.");
        return Plugin_Handled;
    }

    if (!IsTickrateEnablerAvailable())
    {
        PrintToChat(client, "[\x04Tickrate\x01] Plugin [L4D2] Tickrate Enabler nao encontrado.");
        return Plugin_Handled;
    }

    if (IsBuiltinVoteInProgress())
    {
        PrintToChat(client, "[\x04Tickrate\x01] Ja existe uma votacao em andamento.");
        return Plugin_Handled;
    }

    PrintToChat(client, "[\x04Tickrate\x01] Se a votacao passar, o mapa sera reiniciado.");
    ShowTickrateMenu(client);
    return Plugin_Handled;
}

void ShowTickrateMenu(int client)
{
    Menu menu = new Menu(TickrateMenuHandler);
    menu.SetTitle("Escolha o tickrate");
    menu.AddItem("30", "30 (vanilla)");
    menu.AddItem("64", "64 (cs tick)");
    menu.AddItem("100", "100");
    menu.AddItem("128", "128 (allow server)");
    menu.ExitButton = true;
    menu.Display(client, 20);
}

public int TickrateMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_Select)
    {
        char sTickrate[8];
        menu.GetItem(param2, sTickrate, sizeof(sTickrate));

        int iTickrate = StringToInt(sTickrate);
        StartTickrateVote(param1, iTickrate);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

bool StartTickrateVote(int client, int tickrate)
{
    if (!IsClientInGame(client) || GetClientTeam(client) <= TEAM_SPECTATE)
    {
        return false;
    }

    if (!IsTickrateEnablerAvailable())
    {
        PrintToChat(client, "[\x04Tickrate\x01] Plugin de tickrate indisponivel.");
        return false;
    }

    if (IsBuiltinVoteInProgress())
    {
        PrintToChat(client, "[\x04Tickrate\x01] Ja existe uma votacao em andamento.");
        return false;
    }

    int[] iPlayers = new int[MaxClients];
    int iNumPlayers = 0;
    int iConnectedCount = ProcessPlayers(iPlayers, iNumPlayers);

    if (iConnectedCount > 0)
    {
        PrintToChat(client, "[\x04Tickrate\x01] Aguarde jogadores conectando...");
        return false;
    }

    if (iNumPlayers < 1)
    {
        PrintToChat(client, "[\x04Tickrate\x01] Players insuficientes.");
        return false;
    }

    g_hVote = CreateBuiltinVote(VoteActionHandler, BuiltinVoteType_Custom_YesNo, BuiltinVoteAction_Cancel | BuiltinVoteAction_VoteEnd | BuiltinVoteAction_End);

    char sTitle[96];
    Format(sTitle, sizeof(sTitle), "Mudar tickrate para %d e reiniciar mapa?", tickrate);

    SetBuiltinVoteArgument(g_hVote, sTitle);
    SetBuiltinVoteInitiator(g_hVote, client);
    SetBuiltinVoteResultCallback(g_hVote, TickrateVoteResultHandler);

    g_iPendingTickrate = tickrate;
    g_sCurrentVoteStarter[0] = '\0';

    DisplayBuiltinVote(g_hVote, iPlayers, iNumPlayers, 20);
    PrintToChatAll("[\x04Tickrate\x01] \x03%N \x01iniciou voto para tickrate \x05%d\x01. Se passar, o mapa reinicia.", client, tickrate);

    if (iNumPlayers == 1)
    {
        DisplayBuiltinVotePass(g_hVote, "Aplicando tickrate e reiniciando mapa...");
        CreateTimer(1.0, Timer_ApplyTickrateAndRestart, tickrate);
    }
    else
    {
        FakeClientCommand(client, "Vote Yes");
    }

    return true;
}

void TickrateVoteResultHandler(Handle vote, int num_votes, int num_clients, const int[][] client_info, int num_items, const int[][] item_info)
{
    for (int i = 0; i < num_items; i++)
    {
        if (item_info[i][BUILTINVOTEINFO_ITEM_INDEX] == BUILTINVOTES_VOTE_YES)
        {
            if (item_info[i][BUILTINVOTEINFO_ITEM_VOTES] > (num_votes / 2))
            {
                DisplayBuiltinVotePass(vote, "Aplicando tickrate e reiniciando mapa...");
                CreateTimer(1.0, Timer_ApplyTickrateAndRestart, g_iPendingTickrate);
                return;
            }
        }
    }

    DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Loses);
}

public Action Timer_ApplyTickrateAndRestart(Handle timer, any data)
{
    int iTickrate = data;
    if (!TrySetTickrateConVar(iTickrate))
    {
        PrintToChatAll("[\x04Tickrate\x01] Cvar l4d2_tickrate_enabler_tick nao encontrada.");
        return Plugin_Stop;
    }

    SaveTickrateForCurrentServer(iTickrate);

    char sCurrentMap[64];
    GetCurrentMap(sCurrentMap, sizeof(sCurrentMap));

    PrintToChatAll("[\x04Tickrate\x01] Tickrate alterado para %d. Reiniciando mapa...", iTickrate);
    ForceChangeLevel(sCurrentMap, "Tickrate vote passed");
    return Plugin_Stop;
}

bool IsTickrateEnablerAvailable()
{
    if (!IsTickrateEnablerPluginLoaded())
    {
        return false;
    }

    return (FindConVar("l4d2_tickrate_enabler_tick") != null);
}

bool IsTickrateEnablerPluginLoaded()
{
    Handle hIter = GetPluginIterator();
    bool bFound = false;
    char sName[128];
    char sAuthor[128];

    while (MorePlugins(hIter))
    {
        Handle hPlugin = ReadPlugin(hIter);

        if (GetPluginStatus(hPlugin) != Plugin_Running)
        {
            continue;
        }

        if (!GetPluginInfo(hPlugin, PlInfo_Name, sName, sizeof(sName)))
        {
            continue;
        }

        if (!GetPluginInfo(hPlugin, PlInfo_Author, sAuthor, sizeof(sAuthor)))
        {
            sAuthor[0] = '\0';
        }

        if (StrEqual(sName, "[L4D2] Tickrate Enabler", false)
            && StrContains(sAuthor, "BHaType", false) != -1
            && StrContains(sAuthor, "Satanic Spirit", false) != -1)
        {
            bFound = true;
            break;
        }
    }

    delete hIter;
    return bFound;
}

void InitTickrateDatabase()
{
    char sError[256];
    g_hTickrateDb = SQLite_UseDatabase("kab_tickrate", sError, sizeof(sError));
    if (g_hTickrateDb == null)
    {
        LogError("[Tickrate] Falha ao abrir DB kab_tickrate: %s", sError);
        return;
    }

    static const char sCreateTable[] = "CREATE TABLE IF NOT EXISTS kab_tickrate_servers ("
        ... "server_name TEXT PRIMARY KEY,"
        ... "tickrate INTEGER NOT NULL DEFAULT 30,"
        ... "updated_at INTEGER NOT NULL DEFAULT 0"
        ... ");";

    if (!SQL_FastQuery(g_hTickrateDb, sCreateTable))
    {
        SQL_GetError(g_hTickrateDb, sError, sizeof(sError));
        LogError("[Tickrate] Falha ao criar tabela: %s", sError);
    }
}

void GetCurrentServerKey(char[] key, int maxlen)
{
    if (g_hHostname != null)
    {
        g_hHostname.GetString(key, maxlen);
    }
    else
    {
        key[0] = '\0';
    }

    TrimString(key);
    if (key[0] == '\0')
    {
        strcopy(key, maxlen, "unknown_server");
    }
}

int NormalizeTickrate(int tickrate)
{
    if (tickrate == 64 || tickrate == 100 || tickrate == 128)
    {
        return tickrate;
    }

    return 30;
}

bool GetSavedTickrateForCurrentServer(int &tickrate)
{
    if (g_hTickrateDb == null)
    {
        return false;
    }

    char sServer[192];
    char sServerEscaped[384];
    char sQuery[512];

    GetCurrentServerKey(sServer, sizeof(sServer));
    if (!SQL_EscapeString(g_hTickrateDb, sServer, sServerEscaped, sizeof(sServerEscaped)))
    {
        strcopy(sServerEscaped, sizeof(sServerEscaped), sServer);
    }

    Format(sQuery, sizeof(sQuery),
        "SELECT tickrate FROM kab_tickrate_servers WHERE server_name = '%s' LIMIT 1;",
        sServerEscaped);

    DBResultSet rs = SQL_Query(g_hTickrateDb, sQuery);
    if (rs == null)
    {
        char sError[256];
        SQL_GetError(g_hTickrateDb, sError, sizeof(sError));
        LogError("[Tickrate] Falha ao ler tickrate salvo: %s", sError);
        return false;
    }

    bool bFound = false;
    if (SQL_FetchRow(rs))
    {
        tickrate = NormalizeTickrate(SQL_FetchInt(rs, 0));
        bFound = true;
    }

    delete rs;
    return bFound;
}

void SaveTickrateForCurrentServer(int tickrate)
{
    if (g_hTickrateDb == null)
    {
        return;
    }

    tickrate = NormalizeTickrate(tickrate);

    char sServer[192];
    char sServerEscaped[384];
    char sQuery[640];

    GetCurrentServerKey(sServer, sizeof(sServer));
    if (!SQL_EscapeString(g_hTickrateDb, sServer, sServerEscaped, sizeof(sServerEscaped)))
    {
        strcopy(sServerEscaped, sizeof(sServerEscaped), sServer);
    }

    Format(sQuery, sizeof(sQuery),
        "INSERT OR REPLACE INTO kab_tickrate_servers (server_name, tickrate, updated_at) "
        ... "VALUES ('%s', %d, %d);",
        sServerEscaped, tickrate, GetTime());

    if (!SQL_FastQuery(g_hTickrateDb, sQuery))
    {
        char sError[256];
        SQL_GetError(g_hTickrateDb, sError, sizeof(sError));
        LogError("[Tickrate] Falha ao salvar tickrate: %s", sError);
    }
}

void ApplySavedTickrateForCurrentServer()
{
    int iSavedTickrate = 30;
    if (!GetSavedTickrateForCurrentServer(iSavedTickrate))
    {
        iSavedTickrate = 30;
        SaveTickrateForCurrentServer(iSavedTickrate);
    }

    TrySetTickrateConVar(iSavedTickrate);
}

bool TrySetTickrateConVar(int tickrate)
{
    ConVar hTickrateCvar = FindConVar("l4d2_tickrate_enabler_tick");
    if (hTickrateCvar == null)
    {
        return false;
    }

    tickrate = NormalizeTickrate(tickrate);
    hTickrateCvar.IntValue = tickrate;
    ApplyTickrateExtraCommands(tickrate);
    return true;
}

bool ShouldApplyDedicatedServFpsMax()
{
    return (g_hCvarDedicatedServ != null && g_hCvarDedicatedServ.IntValue != 0);
}

void CacheManagedConVar(const char[] name, ConVar &convar, bool &hooked)
{
    if (convar == null)
    {
        convar = FindConVar(name);
    }

    if (convar != null && !hooked)
    {
        convar.AddChangeHook(OnManagedCvarChanged);
        hooked = true;
    }
}

void RefreshManagedConVarHooks()
{
    CacheManagedConVar("tick_door_speed", g_hTickDoorSpeed, g_bHookedTickDoorSpeed);
    CacheManagedConVar("l4d_pistol_delay_dualies", g_hPistolDelayDualies, g_bHookedPistolDelayDualies);
    CacheManagedConVar("l4d_pistol_delay_single", g_hPistolDelaySingle, g_bHookedPistolDelaySingle);
    CacheManagedConVar("l4d_pistol_delay_incapped", g_hPistolDelayIncapped, g_bHookedPistolDelayIncapped);
    CacheManagedConVar("fps_max", g_hFpsMax, g_bHookedFpsMax);
}

void EnforceManagedCvarProfile()
{
    if (!g_bHasManagedCvarProfile)
    {
        return;
    }

    RefreshManagedConVarHooks();
    g_bApplyingManagedCvars = true;

    if (g_hTickDoorSpeed != null)
    {
        g_hTickDoorSpeed.FloatValue = g_fManagedDoorSpeed;
    }

    if (g_hPistolDelayDualies != null)
    {
        g_hPistolDelayDualies.FloatValue = g_fManagedDualiesDelay;
    }

    if (g_hPistolDelaySingle != null)
    {
        g_hPistolDelaySingle.FloatValue = g_fManagedSingleDelay;
    }

    if (g_hPistolDelayIncapped != null)
    {
        g_hPistolDelayIncapped.FloatValue = g_fManagedIncappedDelay;
    }

    if (g_bManagedFpsEnabled && g_hFpsMax != null)
    {
        g_hFpsMax.IntValue = g_iManagedFpsMax;
    }

    g_bApplyingManagedCvars = false;
}

void ApplyTickrateExtraCommands(int tickrate)
{
    tickrate = NormalizeTickrate(tickrate);

    switch (tickrate)
    {
        case 128:
        {
            g_fManagedDoorSpeed = 1.9;
            g_iManagedFpsMax = 150;
        }
        case 100:
        {
            g_fManagedDoorSpeed = 1.6;
            g_iManagedFpsMax = 120;
        }
        case 64:
        {
            g_fManagedDoorSpeed = 1.1;
            g_iManagedFpsMax = 80;
        }
        default:
        {
            g_fManagedDoorSpeed = 1.0;
            g_iManagedFpsMax = 40;
        }
    }

    g_fManagedDualiesDelay = 0.1;
    g_fManagedSingleDelay = 0.2;
    g_fManagedIncappedDelay = 0.3;
    g_bManagedFpsEnabled = ShouldApplyDedicatedServFpsMax();
    g_bHasManagedCvarProfile = true;

    EnforceManagedCvarProfile();
}

public void OnManagedCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (g_bApplyingManagedCvars || !g_bHasManagedCvarProfile)
    {
        return;
    }

    EnforceManagedCvarProfile();
}

public void OnDedicatedServModeChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (g_bApplyingManagedCvars)
    {
        return;
    }

    ApplySavedTickrateForCurrentServer();
}

int GetHumanPlayerCount()
{
    int iCount = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            iCount++;
        }
    }

    return iCount;
}

bool StartKickBotsVote(int client)
{
    if (IsVersusLikeMode())
    {
        char sMode[64];
        if (g_hGameMode != null)
        {
            g_hGameMode.GetString(sMode, sizeof(sMode));
        }
        else
        {
            strcopy(sMode, sizeof(sMode), "unknown");
        }

        PrintToChat(client, "[\x04Vote\x01] Kick bots bloqueado em modo versus (%s).", sMode);
        return false;
    }

    if (GetClientTeam(client) <= TEAM_SPECTATE)
    {
        PrintToChat(client, "[\x04Vote\x01] Espectadores não iniciam votação.");
        return false;
    }

    if (IsBuiltinVoteInProgress())
    {
        PrintToChat(client, "[\x04Vote\x01] Já existe uma votação em andamento.");
        return false;
    }

    int[] iPlayers = new int[MaxClients];
    int iNumPlayers = 0;
    int iConnectedCount = ProcessPlayers(iPlayers, iNumPlayers);

    if (iConnectedCount > 0)
    {
        PrintToChat(client, "[\x04Vote\x01] Aguarde jogadores conectando...");
        return false;
    }

    if (iNumPlayers < g_hCvarPlayerLimit.IntValue)
    {
        PrintToChat(client, "[\x04Vote\x01] Players insuficientes.");
        return false;
    }

    // Criar o voto (Tipo 3 do seu .inc)
    g_hVote = CreateBuiltinVote(VoteActionHandler, BuiltinVoteType_Custom_YesNo, BuiltinVoteAction_Cancel | BuiltinVoteAction_VoteEnd | BuiltinVoteAction_End);
    
    char sTitle[64];
    Format(sTitle, sizeof(sTitle), "Kickar todos os bots?");

    SetBuiltinVoteArgument(g_hVote, sTitle);
    SetBuiltinVoteInitiator(g_hVote, client);
    SetBuiltinVoteResultCallback(g_hVote, KickVoteResultHandler);
    g_iPendingTickrate = 0;
    GetClientVoteKey(client, g_sCurrentVoteStarter, sizeof(g_sCurrentVoteStarter));
    
    // 1. ABRE O VOTO
    DisplayBuiltinVote(g_hVote, iPlayers, iNumPlayers, 20);

    // --- LÓGICA DE SIMULAÇÃO (O QUE VOCÊ PEDIU) ---
    if (iNumPlayers == 1)
    {
        // Se estiver solo, não esperamos o jogador votar. 
        // Forçamos a Engine a mostrar a tela de "Passou" agora mesmo.
        DisplayBuiltinVotePass(g_hVote, "Removendo bots...");
        CreateTimer(1.0, Timer_KickBots); 
        PrintToChatAll("[\x04Vote\x01] Votação aprovada pelo único jogador.");
    }
    else
    {
        // Se tiver mais gente, faz o sistema normal do Zone: vota Sim e espera os outros
        FakeClientCommand(client, "Vote Yes");
        PrintToChatAll("[\x04Vote\x01] \x03%N \x01iniciou uma votação.", client);
    }
    
    return true;
}

// Essa função só vai ser usada se tiver 2 ou mais pessoas
void KickVoteResultHandler(Handle vote, int num_votes, int num_clients, const int[][] client_info, int num_items, const int[][] item_info)
{
    for (int i = 0; i < num_items; i++)
    {
        if (item_info[i][BUILTINVOTEINFO_ITEM_INDEX] == BUILTINVOTES_VOTE_YES)
        {
            if (item_info[i][BUILTINVOTEINFO_ITEM_VOTES] > (num_votes / 2))
            {
                DisplayBuiltinVotePass(vote, "Removendo bots...");
                CreateTimer(1.0, Timer_KickBots);
                return;
            }
        }
    }
    MarkCurrentVoteStarterAsDenied();
    DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Loses);
}

public void VoteActionHandler(Handle vote, BuiltinVoteAction action, int param1, int param2)
{
    if (action == BuiltinVoteAction_End)
    {
        delete vote;
        g_hVote = null;
        g_iPendingTickrate = 0;
        g_sCurrentVoteStarter[0] = '\0';
    }
    else if (action == BuiltinVoteAction_Cancel)
    {
        DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Generic);
    }
}

void GetClientVoteKey(int client, char[] key, int maxlen)
{
    if (!GetClientAuthId(client, AuthId_Steam2, key, maxlen, true))
    {
        int iUserId = GetClientUserId(client);
        Format(key, maxlen, "uid:%d", iUserId);
    }
}

bool IsClientDeniedThisMap(int client)
{
    if (g_hDeniedThisMap == null)
    {
        return false;
    }

    char sKey[64];
    int iValue;
    GetClientVoteKey(client, sKey, sizeof(sKey));
    return g_hDeniedThisMap.GetValue(sKey, iValue);
}

void MarkCurrentVoteStarterAsDenied()
{
    if (g_hDeniedThisMap == null || g_sCurrentVoteStarter[0] == '\0')
    {
        return;
    }

    g_hDeniedThisMap.SetValue(g_sCurrentVoteStarter, 1, true);
}

bool IsVersusLikeMode()
{
    if (g_hGameMode == null)
    {
        return false;
    }

    char sMode[64];
    g_hGameMode.GetString(sMode, sizeof(sMode));
    return (StrContains(sMode, "versus", false) != -1);
}

int ProcessPlayers(int[] iPlayers, int &iNumPlayers)
{
    int iConnectedCount = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            if (IsClientConnected(i)) iConnectedCount++;
        }
        else
        {
            if (!IsFakeClient(i) && GetClientTeam(i) > TEAM_SPECTATE)
                iPlayers[iNumPlayers++] = i;
        }
    }
    return iConnectedCount;
}

public Action Timer_KickBots(Handle timer)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsFakeClient(i))
            KickClient(i, "Bots removidos.");
    }
    return Plugin_Stop;
}

public Action Timer_ResetTickrateIfStillEmpty(Handle timer)
{
    g_hEmptyResetTimer = null;

    if (GetHumanPlayerCount() == 0)
    {
        g_bHadHumanPlayers = false;
        SaveTickrateForCurrentServer(30);
        if (TrySetTickrateConVar(30))
        {
            char sCurrentMap[64];
            GetCurrentMap(sCurrentMap, sizeof(sCurrentMap));
            ForceChangeLevel(sCurrentMap, "Empty server tickrate reset");
        }
    }

    return Plugin_Stop;
}

public void OnPluginEnd()
{
    if (g_hAnnounceTimer != null)
    {
        delete g_hAnnounceTimer;
        g_hAnnounceTimer = null;
    }

    if (g_hEmptyResetTimer != null)
    {
        delete g_hEmptyResetTimer;
        g_hEmptyResetTimer = null;
    }

    if (g_hTickrateDb != null)
    {
        delete g_hTickrateDb;
        g_hTickrateDb = null;
    }
}



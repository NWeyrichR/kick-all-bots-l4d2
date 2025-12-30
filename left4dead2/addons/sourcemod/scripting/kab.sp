#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

// Usando o SEU arquivo .inc (Custom_YesNo = 3, YES = 1)
#undef REQUIRE_PLUGIN
#include <builtinvotes>

#define TEAM_SPECTATE 1

Handle g_hVote = null;
float g_fLastVoteTime[MAXPLAYERS + 1];

ConVar g_hCvarCooldown = null;
ConVar g_hCvarPlayerLimit = null;

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
    
    g_hCvarCooldown = CreateConVar("sm_kickbots_cooldown", "30.0", "Tempo de espera", FCVAR_NOTIFY);
    g_hCvarPlayerLimit = CreateConVar("sm_kickbots_player_limit", "1", "Mínimo de players", FCVAR_NOTIFY);
}

public Action Command_KickBots(int client, int args)
{
    if (client == 0) return Plugin_Handled;

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

bool StartKickBotsVote(int client)
{
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
    DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Loses);
}

public void VoteActionHandler(Handle vote, BuiltinVoteAction action, int param1, int param2)
{
    if (action == BuiltinVoteAction_End)
    {
        delete vote;
        g_hVote = null;
    }
    else if (action == BuiltinVoteAction_Cancel)
    {
        DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Generic);
    }
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
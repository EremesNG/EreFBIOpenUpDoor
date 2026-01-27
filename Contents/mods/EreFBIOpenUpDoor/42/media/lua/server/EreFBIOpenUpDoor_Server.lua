-- media/lua/server/EreFBIOpenUpDoor_Server.lua

if not isServer() then return end

local Commands = {}

-- Function that receives the command from the source Client.
Commands.ZombieShoveSync = function(player, args)
    -- args contains: { zombies = { {id=123, type="knock"}, {id=456, type="stagger"} } }

    -- Retransmit this command to ALL connected clients.
    -- The module is named "EreFBI" and the command "SyncShove".
    sendServerCommand("EreFBI", "SyncShove", args)
end

local function OnClientCommand(module, command, player, args)
    if module == "EreFBI" and Commands[command] then
        Commands[command](player, args)
    end
end

Events.OnClientCommand.Add(OnClientCommand)
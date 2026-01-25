-- media/lua/server/EreFBIOpenUpDoor_Server.lua

if not isServer() then return end

local Commands = {}

-- Función que recibe la orden del Cliente A
Commands.ZombieShoveSync = function(player, args)
    -- args contiene: { zombies = { {id=123, type="knock"}, {id=456, type="stagger"} } }

    -- Retransmitimos este comando a TODOS los clientes conectados.
    -- El módulo se llama "EreFBI" y el comando "SyncShove".
    sendServerCommand("EreFBI", "SyncShove", args)
end

local function OnClientCommand(module, command, player, args)
    if module == "EreFBI" and Commands[command] then
        Commands[command](player, args)
    end
end

Events.OnClientCommand.Add(OnClientCommand)
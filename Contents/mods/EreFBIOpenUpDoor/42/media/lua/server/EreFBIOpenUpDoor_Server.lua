-- media/lua/server/EreFBIOpenUpDoor_Server.lua

if not isServer() then return end

-- Internal balance constants
local FITNESS_REDUCTION_PER_LEVEL = 0.05 -- 5% cost reduction per Fitness level

local function nowMs()
    if getTimestampMs then return getTimestampMs() end
    return os.time() * 1000
end

-- Simple Anti-spam per player
local _lastBreachCostAt = {}
local function canApplyCost(player)
    local id = player and player:getOnlineID() or -1
    if id == -1 then id = tostring(player) end
    local t = nowMs()
    local last = _lastBreachCostAt[id]
    if last and (t - last) < 150 then
        return false
    end
    _lastBreachCostAt[id] = t
    return true
end

local _lastDashAt = {}
local function canDash(player)
    local id = player and player:getOnlineID() or -1
    local t = nowMs()
    local last = _lastDashAt[id]
    if last and (t - last) < 150 then
        return false
    end
    _lastDashAt[id] = t
    return true
end

local Commands = {}

-- Function that receives the command from the source Client.
Commands.ZombieShoveSync = function(player, args)
    -- args contains: { zombies = { {id=123, type="knock"}, {id=456, type="stagger"} } }

    -- Retransmit this command to ALL connected clients.
    -- The module is named "EreFBI" and the command "SyncShove".
    sendServerCommand("EreFBI", "SyncShove", args)
end

Commands.ApplyBreachCost = function(player, args)
    if not player or player:isDead() then return end
    if not canApplyCost(player) then return end

    local root = SandboxVars and SandboxVars.EreFBIOpenUpDoor

    local breachCost = (root ~= nil and tonumber(root.BreachCost)) or 0.01
    local fitnessReducesCost = (root == nil or root.FitnessReducesCost ~= false)
    local fitnessXPGain = (root ~= nil and tonumber(root.FitnessXPGain)) or 2.5

    local stats = player:getStats()
    if not stats then return end

    -- Compute cost (server authoritative)
    local cost = tonumber(breachCost) or 0
    if cost > 0 and fitnessReducesCost and Perks and Perks.Fitness then
        local fitnessLevel = player:getPerkLevel(Perks.Fitness) or 0
        local reductionFactor = fitnessLevel * FITNESS_REDUCTION_PER_LEVEL
        if reductionFactor > 0.9 then reductionFactor = 0.9 end
        cost = cost * (1.0 - reductionFactor)
    end

    -- Apply endurance (Build 42)
    if cost > 0 and CharacterStat and CharacterStat.ENDURANCE then
        local okGet, cur = pcall(function()
            return stats:get(CharacterStat.ENDURANCE)
        end)

        if okGet and type(cur) == "number" then
            local newEnd = cur - cost
            if newEnd < 0 then newEnd = 0 end
            pcall(function()
                stats:set(CharacterStat.ENDURANCE, newEnd)
            end)
        end
    end

    -- XP gain (server authoritative)
    local xpGain = tonumber(fitnessXPGain) or 0
    if xpGain > 0 and Perks and Perks.Fitness then
        local xp = player:getXp()
        if xp then
            xp:AddXP(Perks.Fitness, xpGain, false, true, true)
        end
    end
end

Commands.DoorDashSync = function(player, args)
    if not player or player:isDead() then return end
    if not canDash(player) then return end

    local oid = player:getOnlineID()
    if not oid or oid == -1 then return end

    local durationMs = args and tonumber(args.durationMs) or 1150
    if durationMs < 100 then durationMs = 100 end
    if durationMs > 5000 then durationMs = 5000 end

    sendServerCommand("EreFBI", "SyncDoorDash", {
        playerId = oid,
        durationMs = durationMs,
    })
end

local function OnClientCommand(module, command, player, args)
    if module == "EreFBI" and Commands[command] then
        Commands[command](player, args)
    end
end

Events.OnClientCommand.Add(OnClientCommand)
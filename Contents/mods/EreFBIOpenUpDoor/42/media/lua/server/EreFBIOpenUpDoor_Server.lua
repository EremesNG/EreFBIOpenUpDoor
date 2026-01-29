-- media/lua/server/EreFBIOpenUpDoor_Server.lua

if not isServer() then return end

-- Internal balance constants
-- Defines how much the endurance cost is reduced per level of Fitness.
local FITNESS_REDUCTION_PER_LEVEL = 0.05 -- 5% cost reduction per Fitness level

-- =========================================================
-- Helpers
-- =========================================================

-- Returns the current time in milliseconds.
-- Uses getTimestampMs if available, otherwise falls back to os.time().
local function nowMs()
    if getTimestampMs then return getTimestampMs() end
    return os.time() * 1000
end

-- Simple Anti-spam per player to prevent abuse of breach costs.
local _lastBreachCostAt = {}
local function canApplyCost(player)
    local id = player and player:getOnlineID() or -1
    if id == -1 then id = tostring(player) end
    local t = nowMs()
    local last = _lastBreachCostAt[id]
    -- Enforce a 150ms cooldown
    if last and (t - last) < 150 then
        return false
    end
    _lastBreachCostAt[id] = t
    return true
end

-- Rate limiter for the dash action to prevent spamming.
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

-- Checks if the object is a player-built structure (IsoThumpable) that functions as a door.
local function isThumpDoor(obj)
    return instanceof(obj, "IsoThumpable") and obj:isDoor()
end

-- Safely checks if a door is open using pcall to handle potential API differences or errors.
local function doorIsOpen(door)
    local ok, v = pcall(function() return door:IsOpen() end)
    if ok then return v end
    ok, v = pcall(function() return door:isOpen() end)
    if ok then return v end
    return false
end

-- Safely checks if a door is barricaded.
local function doorIsBarricaded(door)
    local ok, v = pcall(function() return door:isBarricaded() end)
    return ok and v or false
end

-- Safely checks if a door is obstructed (blocked by furniture, etc.).
local function doorIsObstructed(door)
    local ok, v = pcall(function() return door:isObstructed() end)
    return ok and v or false
end

-- Safely checks if a door is locked by key or padlock.
local function doorIsLocked(door)
    local okK, lockedKey = pcall(function() return door:isLockedByKey() end)
    if okK and lockedKey then return true end
    local okP, lockedPad = pcall(function() return door:isLockedByPadlock() end)
    if okP and lockedPad then return true end
    return false
end

-- Locates a door object at specific coordinates.
-- Handles both standard doors and thumpable doors, checking orientation (North/West).
local function findDoorAt(x, y, z, north, thumpable)
    local cell = getCell()
    if not cell then return nil end
    local sq = cell:getGridSquare(x, y, z)
    if not sq then return nil end

    if not thumpable then
        local d = sq:getDoor(north == true)
        if d then return d end
        -- Fallback: try the opposite orientation if the first attempt failed
        d = sq:getDoor(north ~= true)
        if d then
            local okN, vN = pcall(function() return d:getNorth() end)
            if (not okN) or (vN == (north == true)) then
                return d
            end
        end
    end

    -- Helper to scan object lists for thumpable doors matching the criteria
    local function scan(list)
        if not list then return nil end
        for i = 0, list:size() - 1 do
            local o = list:get(i)
            if o and isThumpDoor(o) then
                local okN, vN = pcall(function() return o:getNorth() end)
                if (not okN) or (vN == (north == true)) then
                    return o
                end
            end
        end
        return nil
    end

    return scan(sq:getSpecialObjects()) or scan(sq:getObjects())
end

-- =========================================================
-- Commands
-- =========================================================
local Commands = {}

-- Handles the synchronization of zombie shove effects.
-- Receives the command from the source Client and broadcasts it.
Commands.ZombieShoveSync = function(player, args)
    -- args contains: { zombies = { {id=123, type="knock"}, {id=456, type="stagger"} } }

    -- Retransmit this command to ALL connected clients.
    -- The module is named "EreFBI" and the command "SyncShove".
    sendServerCommand("EreFBI", "SyncShove", args)
end

-- Calculates and applies the endurance cost and XP gain for breaching.
-- This logic is server-authoritative to prevent cheating.
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
        -- Cap reduction at 90%
        if reductionFactor > 0.9 then reductionFactor = 0.9 end
        cost = cost * (1.0 - reductionFactor)
    end

    -- Apply endurance reduction (Compatible with Build 42 stats API)
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

    -- Apply XP gain (server authoritative)
    local xpGain = tonumber(fitnessXPGain) or 0
    if xpGain > 0 and Perks and Perks.Fitness then
        local xp = player:getXp()
        if xp then
            xp:AddXP(Perks.Fitness, xpGain, false, true, true)
        end
    end
end

-- Broadcasts the door dash action to other clients for visual sync.
Commands.DoorDashSync = function(player, args)
    if not player or player:isDead() then return end
    if not canDash(player) then return end

    local oid = player:getOnlineID()
    if not oid or oid == -1 then return end

    local durationMs = args and tonumber(args.durationMs) or 1150
    -- Clamp duration to reasonable limits
    if durationMs < 100 then durationMs = 100 end
    if durationMs > 5000 then durationMs = 5000 end

    sendServerCommand("EreFBI", "SyncDoorDash", {
        playerId = oid,
        durationMs = durationMs,
    })
end

-- Validates and executes a request to change a door's state (open/close).
local _doorSpamGuard = {}
Commands.SetDoorState = function(player, args)
    if not player or player:isDead() then return end
    if not args then return end

    local x = tonumber(args.x)
    local y = tonumber(args.y)
    local z = tonumber(args.z)
    if not x or not y or not z then return end

    local north     = (args.north == true)
    local thumpable = (args.thumpable == true)
    local wantOpen  = (args.open == true)

    -- Basic proximity check: Player must be within ~2 tiles of the target
    local dx = player:getX() - (x + 0.5)
    local dy = player:getY() - (y + 0.5)
    if (dx*dx + dy*dy) > (5.0 * 5.0) then
        return
    end

    local doorId = string.format("%d,%d,%d", x, y, z)
    local now = nowMs()

    -- Spam guard: Prevent rapid door toggling
    if _doorSpamGuard[doorId] and now - _doorSpamGuard[doorId] < 500 then
        return
    end
    _doorSpamGuard[doorId] = now

    -- Try to find the door as declared, then fallback to the other type if not found
    local door = findDoorAt(x, y, z, north, thumpable)
    if not door then
        door = findDoorAt(x, y, z, north, not thumpable)
    end
    if not door then return end

    local cur = doorIsOpen(door)
    if cur == wantOpen then return end

    -- Validate rules only when attempting to open the door
    if wantOpen then
        if doorIsBarricaded(door) then return end
        if doorIsLocked(door) then return end
        if doorIsObstructed(door) then return end
    end

    -- Safe toggle (IsoThumpable and IsoDoor both have this method)
    local ok = pcall(function()
        door:ToggleDoor(player) -- IMPORTANT: never pass nil
    end)

    if not ok then
        ok = pcall(function()
            door:toggleDoor(player)
        end)
    end

    if not ok then return end

    pcall(function() door:update() end)

    -- Lightweight Sync (avoids transmitCompleteItemToClients, which often causes index desyncs)
    pcall(function()
        if door.transmitUpdatedSpriteToClients then
            door:transmitUpdatedSpriteToClients()
        elseif door.sendObjectChange then
            door:sendObjectChange("state")
        end
    end)
end

-- =========================================================
-- Events
-- =========================================================

local function OnClientCommand(module, command, player, args)
    if module == "EreFBI" and Commands[command] then
        Commands[command](player, args)
    end
end

Events.OnClientCommand.Add(OnClientCommand)
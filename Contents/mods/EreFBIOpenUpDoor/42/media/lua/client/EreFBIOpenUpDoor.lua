-- EreFBIOpenUp Door (Build 42)
EreFBIOpenUpDoor = EreFBIOpenUpDoor or {}
local MOD = EreFBIOpenUpDoor

-- =========================================================
-- Tunables (Safe default configuration)
-- =========================================================
local RUN_PROBE_INTERVAL_MS = 60
local RUN_PROBE_STEP_DIST   = 0.1
local RUN_PROBE_MAX_DIST    = 0.5
local MIN_RUN_TIME_MS       = 250     -- Minimum running time (ms) to activate logic

local SPRINT_PROBE_INTERVAL_MS = 60
local SPRINT_PROBE_STEP_DIST   = 0.1
local SPRINT_PROBE_MAX_DIST    = 0.8
local ISO_DIR_COMPENSATION     = 0.6
local MIN_SPRINT_TIMER         = 10.0 -- ~70.0 is approx 1 sec.

local AUTO_CLOSE_MIN_DELAY_MS  = 300
local AUTO_CLOSE_ADJACENT_DIST = 1.1
local DOOR_COOLDOWN_MS         = 300
local GATE_SCAN_MAX_TILES      = 3.0

local DASH_VAR         = "EreFBI_DoorDash"
local DASH_DURATION_MS = 1150
local DASH_RUN_DURATION_MULTI = 1.1
local DASH_SPRINT_DURATION_MULTI = 1.5

-- Internal balance constants
local FITNESS_REDUCTION_PER_LEVEL = 0.05 -- 5% cost reduction per Fitness level

MOD._state = MOD._state or {
    pendingClose = {},
    cooldownUntil = {},
    lastSprintProbeAt = 0,
    lastRunProbeAt = 0,
    dashUntilByPlayer = {},
    runningStartedAt = 0,
}


local _localPlayerIndex = 0
local _localPlayerObjIndex = nil

-- =========================================================
-- Helpers: Basics
-- =========================================================
local function nowMs()
    if getTimestampMs then return getTimestampMs() end
    return os.time() * 1000
end

-- Fetch Sandbox Variables with fallback defaults matching configuration settings.
local function sv()
    local root = SandboxVars and SandboxVars.EreFBIOpenUpDoor
    return {
        AutoCloseDoor       = (root ~= nil and root.AutoCloseDoor) or false,
        WhileRunning        = (root == nil or root.WhileRunning ~= true),
        WhileSprinting      = (root == nil or root.WhileSprinting ~= true),

        ShoveNearbyZombies  = (root ~= nil and root.ShoveNearbyZombies) or true,
        ShoveRange          = (root ~= nil and root.ShoveRange) or 1.8,
        ShoveAngle          = (root ~= nil and root.ShoveAngle) or 120.0,
        KnockdownChance     = (root ~= nil and root.KnockdownChance) or 35,

        EnablePropagation   = (root ~= nil and root.EnablePropagation) or true,
        PropagationDepth    = (root ~= nil and root.PropagationDepth) or 2,
        PropagationStrength = (root ~= nil and root.PropagationStrength) or 60,

        EnableAnimation     = (root == nil or root.EnableAnimation ~= true),

        -- New Options
        BreachCost          = (root ~= nil and root.BreachCost) or 0.02,
        FitnessReducesCost  = (root == nil or root.FitnessReducesCost ~= true),
    }
end

local function ZombRandSafe(max)
    if ZombRand then return ZombRand(max) end
    return math.random(max)
end

-- =========================================================
-- Helpers: Geometry & Direction
-- =========================================================
-- Converts an IsoDirection to a local vector (dx, dy).
local function dirToVectorLocal(dir)
    if dir == IsoDirections.N  then return 0, -1 end
    if dir == IsoDirections.S  then return 0,  1 end
    if dir == IsoDirections.E  then return 1,  0 end
    if dir == IsoDirections.W  then return -1, 0 end
    if dir == IsoDirections.NE then return 1, -1 end
    if dir == IsoDirections.NW then return -1,-1 end
    if dir == IsoDirections.SE then return 1,  1 end
    if dir == IsoDirections.SW then return -1, 1 end
    return 0, 0
end

local function dirToVector(dir)
    return dirToVectorLocal(dir)
end

-- Calculates the forward unit vector based on player's facing direction or angle.
local function getForwardUnit(player)
    local ok, ang = pcall(function()
        local fd = player:getForwardDirection()
        return fd and fd:getDirection()
    end)
    if ok and ang then
        return math.cos(ang), math.sin(ang)
    end

    local dx, dy = dirToVectorLocal(player:getDir())
    if dx == 0 and dy == 0 then return 0, 0 end
    if dx ~= 0 and dy ~= 0 then
        local inv = 1 / math.sqrt(2)
        dx, dy = dx * inv, dy * inv
    end
    return dx, dy
end

-- Returns a simplified step direction (1, 0, -1) for grid propagation.
local function getForwardStep(player)
    local fx, fy = getForwardUnit(player)
    local sx, sy = 0, 0
    if math.abs(fx) > 0.33 then sx = (fx > 0) and 1 or -1 end
    if math.abs(fy) > 0.33 then sy = (fy > 0) and 1 or -1 end
    return sx, sy
end

-- Calculates squared distance from a point (px, py) to the center of a target square.
local function distSqToSquareCenter(px, py, sq)
    local cx = sq:getX() + 0.5
    local cy = sq:getY() + 0.5
    local dx = px - cx
    local dy = py - cy
    return dx*dx + dy*dy
end

-- =========================================================
-- Helpers: Door Property Checks
-- =========================================================
-- Checks if object is a thumpable door (player built or specific map objects).
local function isThumpDoor(obj)
    return instanceof(obj, "IsoThumpable") and obj:isDoor()
end

local function isDoor(obj)
    return instanceof(obj, "IsoDoor") or isThumpDoor(obj)
end

-- Safely checks if a door is open (handles both IsoDoor and IsoThumpable).
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
    if ok then return v end
    return false
end

-- Checks if a door is locked (key or padlock).
local function doorIsLocked(player, door)
    if instanceof(door, "IsoDoor") then
        local okExt, isExt = pcall(function() return door:isExteriorDoor(player) end)
        if okExt and isExt then
            local ok, v = pcall(function() return door:isLockedByKey() end)
            return ok and v or false
        end
        return false
    end
    local okK, lockedKey = pcall(function() return door:isLockedByKey() end)
    if okK and lockedKey then return true end
    local okP, lockedPad = pcall(function() return door:isLockedByPadlock() end)
    if okP and lockedPad then return true end
    return false
end

-- Checks obstruction for large gates/double doors across multiple squares.
local function getThumpObstructedAcrossSquares(thumpDoor)
    local sq = thumpDoor:getSquare()
    if not sq then return true end

    local function checkSq(s)
        if not s then return false end
        local so = s:getSpecialObjects()
        if so then
            for i = 0, so:size() - 1 do
                local o = so:get(i)
                if o and isDoor(o) then
                    local ok, v = pcall(function() return o:isObstructed() end)
                    if ok and v then return true end
                end
            end
        end
        local objs = s:getObjects()
        if objs then
            for i = 0, objs:size() - 1 do
                local o = objs:get(i)
                if o and isDoor(o) then
                    local ok, v = pcall(function() return o:isObstructed() end)
                    if ok and v then return true end
                end
            end
        end
        return false
    end

    local north = thumpDoor:getNorth()
    if north then
        if checkSq(sq:getE()) then return true end
        if checkSq(sq:getW()) then return true end
    else
        if checkSq(sq:getN()) then return true end
        if checkSq(sq:getS()) then return true end
    end
    return false
end

-- General check if a door is obstructed by objects or zombies.
local function doorIsObstructed(door)
    local ok, v = pcall(function() return door:isObstructed() end)
    if ok and v then return true end
    if isThumpDoor(door) then
        local ok2, v2 = pcall(getThumpObstructedAcrossSquares, door)
        if ok2 and v2 then return true end
    end
    return false
end

-- Validates if the player can interact with the door (not open, not barricaded, etc.).
local function canUseDoor(player, door)
    if not door or not isDoor(door) then return false end
    if doorIsOpen(door) then return false end
    if doorIsBarricaded(door) then return false end
    if doorIsLocked(player, door) then return false end
    if doorIsObstructed(door) then return false end
    return true
end

-- =========================================================
-- Helpers: Multi-tile Gate Scanning
-- =========================================================
local function spriteNameSafe(obj)
    local ok, sp = pcall(function() return obj:getSprite() end)
    if ok and sp then
        local ok2, name = pcall(function() return sp:getName() end)
        if ok2 then return name end
    end
    return nil
end

local function northSafe(obj, fallback)
    local ok, v = pcall(function() return obj:getNorth() end)
    if ok then return v end
    return fallback
end

-- Finds a gate part on a specific square that matches the base door's properties.
local function findMatchingGatePartOnSquare(baseDoor, sq)
    if not sq then return nil end
    local baseNorth = northSafe(baseDoor, false)
    local baseSprite = spriteNameSafe(baseDoor)

    local function matches(o)
        if not o or not isThumpDoor(o) then return false end
        if northSafe(o, baseNorth) ~= baseNorth then return false end

        local sn = spriteNameSafe(o)
        if baseSprite and sn and sn ~= baseSprite then return false end

        if doorIsOpen(o) ~= doorIsOpen(baseDoor) then
        end

        return true
    end

    local so = sq:getSpecialObjects()
    if so then
        for i = 0, so:size() - 1 do
            local o = so:get(i)
            if matches(o) then return o end
        end
    end
    local objs = sq:getObjects()
    if objs then
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            if matches(o) then return o end
        end
    end
    return nil
end

-- Returns all squares occupied by a door (handles multi-tile gates).
local function getDoorOriginSquares(door)
    local out, seen = {}, {}
    local sq = door and door:getSquare()
    if not sq then return out end

    local function addSq(s)
        if not s then return end
        local key = string.format("%d:%d:%d", s:getX(), s:getY(), s:getZ())
        if seen[key] then return end
        seen[key] = true
        table.insert(out, s)
    end

    addSq(sq)

    if not isThumpDoor(door) then
        return out
    end

    local north = northSafe(door, false)

    local function stepE(s) return s and s:getE() end
    local function stepW(s) return s and s:getW() end
    local function stepN(s) return s and s:getN() end
    local function stepS(s) return s and s:getS() end

    local stepPos, stepNeg
    if north then
        stepPos, stepNeg = stepE, stepW
    else
        stepPos, stepNeg = stepN, stepS
    end

    local cur = sq
    for _ = 1, GATE_SCAN_MAX_TILES do
        cur = stepPos(cur)
        if not cur then break end
        local part = findMatchingGatePartOnSquare(door, cur)
        if not part then break end
        addSq(cur)
    end

    cur = sq
    for _ = 1, GATE_SCAN_MAX_TILES do
        cur = stepNeg(cur)
        if not cur then break end
        local part = findMatchingGatePartOnSquare(door, cur)
        if not part then break end
        addSq(cur)
    end

    return out
end

-- =========================================================
-- Helpers: Zombie Shove & Propagation
-- =========================================================
-- Checks if a zombie is valid for shoving/staggering.
local function isStaggerableZombie(z)
    return z
            and instanceof(z, "IsoZombie")
            and not z:isDead()
            and not z:isKnockedDown()
end

-- Determines if a zombie is within a cone in front of the door/player.
local function inOutwardCone(player, doorCx, doorCy, zombie, angleDeg)
    if angleDeg >= 180 then return true end
    if angleDeg <= 0 then
        angleDeg = 0.1
    end
    local angleRad = math.rad(angleDeg)
    local cosThr = math.cos(angleRad)

    local zx, zy = zombie:getX(), zombie:getY()
    local dx, dy = zx - doorCx, zy - doorCy
    local dist = math.sqrt(dx*dx + dy*dy)
    if dist <= 0.001 then return false end
    dx, dy = dx / dist, dy / dist

    local fx, fy = getForwardUnit(player)
    if fx == 0 and fy == 0 then return true end

    return (dx*fx + dy*fy) >= cosThr
end

-- Applies knockdown or stagger to a zombie based on chance.
local function applyEffectToZombie(z, knockChance)
    if ZombRandSafe(100) < knockChance then
        z:setKnockedDown(true)
    else
        z:setStaggerBack(true)
    end
end

-- Propagates the shove effect to zombies behind the initial target.
local function propagateForward(fromZombie, depth, propStrength, knockChance, stepX, stepY, processed)
    if depth <= 0 then return end
    if stepX == 0 and stepY == 0 then return end
    if not isStaggerableZombie(fromZombie) then return end

    local sq = fromZombie:getSquare()
    if not sq then return end
    local cell = sq:getCell()
    if not cell then return end

    local nextSq = cell:getGridSquare(sq:getX() + stepX, sq:getY() + stepY, sq:getZ())
    if not nextSq then return end

    local mobs = nextSq:getMovingObjects()
    if not mobs then return end

    local nextCarrier = nil
    for i = 0, mobs:size() - 1 do
        local other = mobs:get(i)
        if isStaggerableZombie(other) and not (processed and processed[other]) then
            if ZombRandSafe(100) < propStrength then
                applyEffectToZombie(other, knockChance)
                if processed then processed[other] = true end
                if not nextCarrier then nextCarrier = other end
            end
        end
    end

    if nextCarrier then
        propagateForward(nextCarrier, depth - 1, propStrength, knockChance, stepX, stepY, processed)
    end
end

-- Applies the shove effect to zombies near the door, handling multiplayer sync.
local function applyDoorShoveLocal(player, originSquares)
    local sbox = sv()
    if not sbox.ShoveNearbyZombies then return end
    if not player or not originSquares or #originSquares == 0 then return end

    local cell = getCell()
    if not cell then return end

    local zlist = cell:getZombieList()
    if not zlist then return end

    local range = tonumber(sbox.ShoveRange) or 1.8
    if range <= 0 then return end
    local r2 = range * range

    local angleDeg = tonumber(sbox.ShoveAngle) or 120.0
    if angleDeg < 0 then angleDeg = 0 elseif angleDeg > 180 then angleDeg = 180 end

    local knockChance = math.floor(tonumber(sbox.KnockdownChance) or 35)
    if knockChance < 0 then knockChance = 0 elseif knockChance > 100 then knockChance = 100 end

    local doProp = (sbox.EnablePropagation == true)
    local maxDepth = math.floor(tonumber(sbox.PropagationDepth) or 2)
    if maxDepth < 0 then maxDepth = 0 end

    local propStrength = math.floor(tonumber(sbox.PropagationStrength) or 60)
    if propStrength < 0 then propStrength = 0 elseif propStrength > 100 then propStrength = 100 end

    local stepX, stepY = 0, 0
    if doProp and maxDepth > 0 and propStrength > 0 then
        stepX, stepY = getForwardStep(player)
    end

    local processed = {}
    local syncData = {}
    local isMultiplayer = isClient()

    local function applyEffectAndRecord(z, forcedAction)
        if not isStaggerableZombie(z) then return end

        local isKnock = false

        if forcedAction == "knock" then
            isKnock = true
            z:setKnockedDown(true)
        elseif forcedAction == "stagger" then
            isKnock = false
            z:setStaggerBack(true)
        else
            if ZombRandSafe(100) < knockChance then
                z:setKnockedDown(true)
                isKnock = true
            else
                z:setStaggerBack(true)
                isKnock = false
            end
        end

        processed[z] = true

        if isMultiplayer then
            local onlineID = z:getOnlineID()
            if onlineID and onlineID ~= -1 then
                table.insert(syncData, {
                    id = onlineID,
                    action = isKnock and "knock" or "stagger"
                })
            end
        end
    end

    local function propagateRecursive(fromZombie, currentDepth)
        if currentDepth <= 0 then return end
        if stepX == 0 and stepY == 0 then return end

        local sq = fromZombie:getSquare()
        if not sq then return end
        local c = sq:getCell()

        local nextSq = c:getGridSquare(sq:getX() + stepX, sq:getY() + stepY, sq:getZ())
        if not nextSq then return end

        local mobs = nextSq:getMovingObjects()
        if not mobs then return end

        local nextCarrier = nil

        for i = 0, mobs:size() - 1 do
            local other = mobs:get(i)
            if isStaggerableZombie(other) and not processed[other] then
                if ZombRandSafe(100) < propStrength then
                    applyEffectAndRecord(other, nil)
                    if not nextCarrier then nextCarrier = other end
                end
            end
        end

        if nextCarrier then
            propagateRecursive(nextCarrier, currentDepth - 1)
        end
    end

    local carriers = {}

    for _, osq in ipairs(originSquares) do
        if osq then
            local cx = osq:getX() + 0.5
            local cy = osq:getY() + 0.5
            local cz = osq:getZ()

            local carrier = nil

            for i = 0, zlist:size() - 1 do
                local z = zlist:get(i)
                if isStaggerableZombie(z) and z:getZ() == cz and not processed[z] then
                    local dx = z:getX() - cx
                    local dy = z:getY() - cy

                    if (dx*dx + dy*dy) <= r2 then
                        if inOutwardCone(player, cx, cy, z, angleDeg) then
                            applyEffectAndRecord(z, nil)
                            if doProp and not carrier then carrier = z end
                        end
                    end
                end
            end

            if doProp and carrier and maxDepth > 0 and propStrength > 0 then
                table.insert(carriers, carrier)
            end
        end
    end

    if #carriers > 0 then
        for _, c in ipairs(carriers) do
            propagateRecursive(c, maxDepth)
        end
    end

    if isMultiplayer and #syncData > 0 then
        sendClientCommand(player, "EreFBI", "ZombieShoveSync", { zombies = syncData })
    end
end

-- Entry point to request a door shove action.
local function requestDoorShove(player, door)
    local sbox = sv()
    if not sbox.ShoveNearbyZombies then return end
    if not door then return end

    local originSquares = getDoorOriginSquares(door)
    if not originSquares or #originSquares == 0 then return end

    applyDoorShoveLocal(player, originSquares)
end

-- =========================================================
-- Internal State Management (Cooldowns & Keys)
-- =========================================================
-- Generates a unique key for a door based on position and type.
local function doorKeyFrom(door)
    local sq = door:getSquare()
    if not sq then return tostring(door) end
    local north = false
    local okN, vN = pcall(function() return door:getNorth() end)
    if okN then north = vN end
    local kind = isThumpDoor(door) and "T" or "D"
    return string.format("%s:%d:%d:%d:%s", kind, sq:getX(), sq:getY(), sq:getZ(), north and "N" or "W")
end

-- Checks if a specific door key is currently in cooldown.
local function inCooldown(key)
    local untilMs = MOD._state.cooldownUntil[key]
    return untilMs and nowMs() < untilMs
end

-- Sets a cooldown for a specific door key.
local function setCooldown(key, ms)
    MOD._state.cooldownUntil[key] = nowMs() + ms
end

-- =========================================================
-- Door dash (animset selector) - run/sprint
-- =========================================================
-- Helper to delay execution by a number of ticks.
MOD._state.dashCancelByPlayer = MOD._state.dashCancelByPlayer or {}

local function delayTicks(ticks, fn)
    ticks = ticks or 1
    local t = 0
    local canceled = false

    local function onTick()
        if canceled then
            Events.OnTick.Remove(onTick)
            return
        end
        t = t + 1
        if t >= ticks then
            Events.OnTick.Remove(onTick)
            fn()
        end
    end

    Events.OnTick.Add(onTick)
    return function()
        canceled = true
        Events.OnTick.Remove(onTick)
    end
end

-- Sets the dash animation variable on the player.
local function setDashVar(player, value)
    pcall(function() player:setVariable(DASH_VAR, value) end)
end

-- Gets a unique key for the player for dash tracking.
local function getDashKey(player)
    return tostring(player:getObjectIndex() or player)
end

-- Triggers the door dash animation variable on the player.
local function triggerDoorDashAnim(player)
    if not player then return end
    local t = nowMs()
    local k = getDashKey(player)

    local untilMs = MOD._state.dashUntilByPlayer[k]
    if untilMs and t < untilMs then 
        return -- Already dashing, do not re-trigger
    end

    local durationMs = DASH_DURATION_MS
    -- Adjust duration based on movement speed
    if player:IsRunning() then
        durationMs = durationMs / DASH_RUN_DURATION_MULTI
    elseif player:isSprinting() then
        durationMs = durationMs / DASH_SPRINT_DURATION_MULTI
    end

    setDashVar(player, true)
    MOD._state.dashUntilByPlayer[k] = t + durationMs
end

-- Updates the door dash animation state, resetting it after duration.
local function updateDoorDashAnim()
    local player = getSpecificPlayer(_localPlayerIndex or 0)
    if not player then return end

    local k = getDashKey(player)
    local untilMs = MOD._state.dashUntilByPlayer[k]
    if untilMs and nowMs() >= untilMs then
        setDashVar(player, false)
        MOD._state.dashUntilByPlayer[k] = nil
    end
end


-- =========================================================
-- Core Action Logic
-- =========================================================
-- Toggles the door state (Open/Close) safely.
local function toggleDoor(player, door)
    local ok = pcall(function() door:ToggleDoor(player) end)
    if not ok then
        pcall(function() door:toggleDoor(player) end)
    end
    pcall(function() door:update() end)
end

-- Handle the "Open Up" action: open door, shove zombies, track state, apply endurance cost.
local function openDoorByMod(player, door)
    local key = doorKeyFrom(door)
    if inCooldown(key) then return end
    if MOD._state.pendingClose[key] ~= nil then return end

    local sbox = sv()

    if sbox.EnableAnimation then
        triggerDoorDashAnim(player)
    end

    delayTicks(1, function()
        toggleDoor(player, door)
        requestDoorShove(player, door)

        local sbox = sv()

        -- =========================================================
        -- ENDURANCE CALCULATION BASED ON FITNESS
        -- =========================================================
        local stats = player:getStats()
        if stats then
            local cost = sbox.BreachCost -- Base

            -- If Fitness option is enabled, apply discount
            if sbox.FitnessReducesCost then
                -- Get Fitness level (0-10)
                local fitnessLevel = player:getPerkLevel(Perks.Fitness)

                -- Calculate reduction: Level * 0.05
                -- Ex: Level 5 * 0.05 = 0.25 (25% less cost)
                -- Ex: Level 10 * 0.05 = 0.50 (50% less cost)
                local reductionFactor = fitnessLevel * FITNESS_REDUCTION_PER_LEVEL

                -- Clamp for safety (max 90% reduction, though level 10 is 50%)
                if reductionFactor > 0.9 then reductionFactor = 0.9 end

                cost = cost * (1.0 - reductionFactor)
            end

            -- Apply the cost
            local currentEndurance = stats:getEndurance()
            local newEndurance = currentEndurance - cost

            if newEndurance < 0 then newEndurance = 0 end
            stats:setEndurance(newEndurance)
        end
        -- =========================================================

        if sbox.AutoCloseDoor then
            local sq = door:getSquare()
            local th = isThumpDoor(door)
            local north = false
            local okN, vN = pcall(function() return door:getNorth() end)
            if okN then north = vN end

            MOD._state.pendingClose[key] = {
                square = sq,
                thumpable = th,
                north = north,
                openedAt = nowMs(),
            }
        end

        setCooldown(key, DOOR_COOLDOWN_MS)
    end)
end

-- =========================================================
-- AutoClose Management
-- =========================================================
-- Attempts to find the door object again (it might have changed reference or state).
local function findDoorNearSquare(state)
    local baseSq = state.square
    if not baseSq then return nil end

    local function scanSquare(sq)
        if not sq then return nil end
        local d1 = sq:getDoor(true)
        if d1 then return d1 end
        local d2 = sq:getDoor(false)
        if d2 then return d2 end

        local so = sq:getSpecialObjects()
        if so then
            for i = 0, so:size() - 1 do
                local o = so:get(i)
                if o and isThumpDoor(o) then
                    local okN, vN = pcall(function() return o:getNorth() end)
                    if not okN or vN == state.north then return o end
                end
            end
        end
        local objs = sq:getObjects()
        if objs then
            for i = 0, objs:size() - 1 do
                local o = objs:get(i)
                if o and isThumpDoor(o) then
                    local okN, vN = pcall(function() return o:getNorth() end)
                    if not okN or vN == state.north then return o end
                end
            end
        end
        return nil
    end

    local candidates = { baseSq }
    if state.thumpable then
        if state.north then
            local s = baseSq
            for _ = 1, 3 do s = s and s:getE(); if s then table.insert(candidates, s) end end
            s = baseSq
            for _ = 1, 3 do s = s and s:getW(); if s then table.insert(candidates, s) end end
        else
            local s = baseSq
            for _ = 1, 3 do s = s and s:getN(); if s then table.insert(candidates, s) end end
            s = baseSq
            for _ = 1, 3 do s = s and s:getS(); if s then table.insert(candidates, s) end end
        end
    else
        table.insert(candidates, baseSq:getN())
        table.insert(candidates, baseSq:getS())
        table.insert(candidates, baseSq:getE())
        table.insert(candidates, baseSq:getW())
    end

    for _, sq in ipairs(candidates) do
        local d = scanSquare(sq)
        if d then return d end
    end
    return nil
end

-- Checks pending auto-close actions and executes them if conditions are met.
local function updateAutoClose()
    local sbox = sv()
    if not sbox.AutoCloseDoor then return end
    local pending = MOD._state.pendingClose
    if not pending then return end

    local player = getSpecificPlayer(_localPlayerIndex or 0)
    if not player or not player:getSquare() then return end

    local t = nowMs()
    for key, state in pairs(pending) do
        if not inCooldown(key) then
            local door = findDoorNearSquare(state)
            if door and doorIsOpen(door) then
                local psq = player:getSquare()
                local dsq = state.square
                if dsq and psq:getZ() == dsq:getZ() then
                    local elapsed = t - (state.openedAt or t)
                    local distSq = distSqToSquareCenter(player:getX(), player:getY(), dsq)
                    local limitSq = AUTO_CLOSE_ADJACENT_DIST * AUTO_CLOSE_ADJACENT_DIST

                    if elapsed >= AUTO_CLOSE_MIN_DELAY_MS and distSq > limitSq then
                        toggleDoor(player, door)
                        pending[key] = nil
                        setCooldown(key, DOOR_COOLDOWN_MS)
                    end
                else
                    pending[key] = nil
                end
            else
                pending[key] = nil
            end
        end
    end
end

-- =========================================================
-- Trigger Handlers: RUNNING & SPRINTING
-- =========================================================
local function onObjectCollide(obj, collided)
    return
end

-- Scans a square for a closed door that the player can interact with.
local function findClosedDoorOnSquare(player, sq)
    if not sq then return nil end
    local d = sq:getDoor(true)
    if d and canUseDoor(player, d) then return d end
    d = sq:getDoor(false)
    if d and canUseDoor(player, d) then return d end

    local so = sq:getSpecialObjects()
    if so then
        for i = 0, so:size() - 1 do
            local o = so:get(i)
            if o and isThumpDoor(o) and canUseDoor(player, o) then return o end
        end
    end
    local objs = sq:getObjects()
    if objs then
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            if o and isThumpDoor(o) and canUseDoor(player, o) then return o end
        end
    end
    return nil
end

-- =========================================================
-- Movement Timer Logic (NEW)
-- =========================================================
-- Tracks how long the player has been running to prevent instant triggers.
local function updateMovementTimers()
    local player = getSpecificPlayer(_localPlayerIndex or 0)
    if not player then return end

    if player:IsRunning() and not player:isSprinting() then
        if MOD._state.runningStartedAt == 0 then
            MOD._state.runningStartedAt = nowMs()
        end
    else
        MOD._state.runningStartedAt = 0
    end
end

-- Probes ahead of the player while running to detect doors.
local function runProbe()
    local sbox = sv()
    if not sbox.WhileRunning then return end

    local player = getSpecificPlayer(_localPlayerIndex or 0)
    if not player or not player:getSquare() then return end

    if player and player:getVariableBoolean("EreFBI_DoorDash") then return end

    if player:isSprinting() then return end
    if not player:IsRunning() then return end

    if MOD._state.runningStartedAt == 0 or (nowMs() - MOD._state.runningStartedAt) < MIN_RUN_TIME_MS then
        return
    end

    local t = nowMs()
    if (t - (MOD._state.lastRunProbeAt or 0)) < RUN_PROBE_INTERVAL_MS then return end
    MOD._state.lastRunProbeAt = t

    local sq = player:getSquare()
    local z = sq:getZ()
    local dx, dy = dirToVector(player:getDir())
    if dx == 0 and dy == 0 then return end

    local px, py = player:getX(), player:getY()

    local ndx, ndy = dx, dy
    if dx ~= 0 and dy ~= 0 then
        local inv = 1 / math.sqrt(2)
        ndx, ndy = dx * inv, dy * inv
    end

    local cell = getCell()

    local currentMaxDist = RUN_PROBE_MAX_DIST

    if ndx > 0 or ndy > 0 then
        currentMaxDist = currentMaxDist + (ISO_DIR_COMPENSATION or 0.6)
    end

    for dist = 0, currentMaxDist, RUN_PROBE_STEP_DIST do
        local tx = math.floor(px + ndx * dist)
        local ty = math.floor(py + ndy * dist)

        if cell then
            local testSq = cell:getGridSquare(tx, ty, z)
            local door = findClosedDoorOnSquare(player, testSq)
            if door then
                openDoorByMod(player, door)
                return
            end
        end
    end
end

-- Probes ahead of the player while sprinting to detect doors.
local function sprintProbe()
    local sbox = sv()
    if not sbox.WhileSprinting then return end

    local player = getSpecificPlayer(_localPlayerIndex or 0)
    if not player or not player:getSquare() then return end

    if player:getVariableBoolean("EreFBI_DoorDash") then return end

    if not player:isSprinting() then return end

    local ok, val = pcall(function() return player:getBeenSprintingFor() end)
    if ok and val and val < MIN_SPRINT_TIMER then
        return
    end

    local t = nowMs()
    if (t - (MOD._state.lastSprintProbeAt or 0)) < SPRINT_PROBE_INTERVAL_MS then return end
    MOD._state.lastSprintProbeAt = t

    local sq = player:getSquare()
    local z = sq:getZ()
    local dx, dy = dirToVector(player:getDir())

    if dx == 0 and dy == 0 then return end

    local cell = getCell()
    local px, py = player:getX(), player:getY()

    local ndx, ndy = dx, dy
    if dx ~= 0 and dy ~= 0 then
        local inv = 1 / math.sqrt(2)
        ndx, ndy = dx * inv, dy * inv
    end

    local currentMaxDist = SPRINT_PROBE_MAX_DIST
    if ndx > 0 or ndy > 0 then
        currentMaxDist = currentMaxDist + ISO_DIR_COMPENSATION
    end

    for dist = 0, currentMaxDist, SPRINT_PROBE_STEP_DIST do
        local tx = math.floor(px + ndx * dist)
        local ty = math.floor(py + ndy * dist)

        if cell then
            local testSq = cell:getGridSquare(tx, ty, z)
            local door = findClosedDoorOnSquare(player, testSq)
            if door then
                openDoorByMod(player, door)
                return
            end
        end
    end
end

-- =========================================================
-- Events
-- =========================================================
-- Handles player creation to store local player index.
local function OnCreatePlayer(playerIndex, player)
    _localPlayerIndex = playerIndex or 0
    if player then
        _localPlayerObjIndex = player:getObjectIndex()
    end
end

-- Main tick loop for updating timers, probes, and auto-close logic.
local function OnTick()
    updateDoorDashAnim()
    updateMovementTimers()
    runProbe()
    sprintProbe()
    updateAutoClose()
end

-- Handles commands received from the server (e.g., syncing shoves).
local function OnServerCommand(module, command, args)
    if module ~= "EreFBI" then return end

    if command == "SyncShove" and args and args.zombies then
        local zombiesToUpdate = args.zombies
        local cell = getCell()
        if not cell then return end
        local zlist = cell:getZombieList()

        local targetZombies = {}
        for _, data in ipairs(zombiesToUpdate) do
            targetZombies[data.id] = data.action
        end

        for i = 0, zlist:size() - 1 do
            local z = zlist:get(i)
            local id = z:getOnlineID()

            if id ~= -1 and targetZombies[id] then
                local action = targetZombies[id]
                if action == "knock" then
                    z:setKnockedDown(true)
                else
                    z:setStaggerBack(true)
                end
                targetZombies[id] = nil
            end
        end
    end
end

Events.OnServerCommand.Add(OnServerCommand)
Events.OnCreatePlayer.Add(OnCreatePlayer)
Events.OnObjectCollide.Add(onObjectCollide)
Events.OnTick.Add(OnTick)

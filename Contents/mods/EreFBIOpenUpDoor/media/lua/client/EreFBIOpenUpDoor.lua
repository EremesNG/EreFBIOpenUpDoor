-- EreFBIOpenUp Door (Build 42)
-- Author: EremesNG
-- Updated: B42 (Run via collide, Sprint via probe, AutoClose via manager)

EreFBIOpenUpDoor = EreFBIOpenUpDoor or {}
local MOD = EreFBIOpenUpDoor

-- =========================================================
-- Tunables (Safe default configuration)
-- =========================================================
local SPRINT_PROBE_INTERVAL_MS = 60   -- How often to probe ahead while sprinting (ms)
local SPRINT_PROBE_STEP_DIST   = 0.5  -- Step distance for probing
local SPRINT_PROBE_MAX_DIST    = 0.5  -- Max distance to probe
local AUTO_CLOSE_MIN_DELAY_MS  = 100  -- Minimum delay after opening before allowing auto-close
local AUTO_CLOSE_ADJACENT_DIST = 0.7  -- Close when distance is no longer adjacent
local DOOR_COOLDOWN_MS         = 300  -- Prevents immediate re-trigger and action stacking

-- Internal state
MOD._state = MOD._state or {
    pendingClose = {},      -- Stores doors waiting to be auto-closed
    cooldownUntil = {},     -- Stores cooldown timestamps for specific doors
    lastSprintProbeAt = 0   -- Timestamp of the last sprint probe
}

local _localPlayerIndex = 0
local _localPlayerObjIndex = nil

-- =========================================================
-- Helpers
-- =========================================================
-- Returns current timestamp in milliseconds
local function nowMs()
    if getTimestampMs then return getTimestampMs() end
    return os.time() * 1000
end

-- Reads SandboxVars.EreFBIOpenUpDoor options with defaults
local function sv()
    -- Reads SandboxVars.EreFBIOpenUpDoor options
    local root = SandboxVars and SandboxVars.EreFBIOpenUpDoor
    return {
        AutoCloseDoor  = (root == nil or root.AutoCloseDoor ~= false),
        WhileRunning   = (root == nil or root.WhileRunning ~= false),
        WhileSprinting = (root == nil or root.WhileSprinting ~= false),
    }
end

-- Checks if object is a player-made door/gate (IsoThumpable)
local function isThumpDoor(obj)
    return instanceof(obj, "IsoThumpable") and obj:isDoor()
end

-- Checks if object is any kind of door (IsoDoor or IsoThumpable)
local function isDoor(obj)
    return instanceof(obj, "IsoDoor") or isThumpDoor(obj)
end

-- Safely checks if a door is open using pcall to handle API variations
local function doorIsOpen(door)
    local ok, v = pcall(function() return door:IsOpen() end)
    if ok then return v end
    ok, v = pcall(function() return door:isOpen() end)
    if ok then return v end
    return false
end

-- Safely checks if a door is barricaded
local function doorIsBarricaded(door)
    local ok, v = pcall(function() return door:isBarricaded() end)
    if ok then return v end
    return false
end

-- Checks if a door is locked (key or padlock)
local function doorIsLocked(player, door)
    if instanceof(door, "IsoDoor") then
        -- Only check locked-by-key for exterior doors
        local okExt, isExt = pcall(function() return door:isExteriorDoor(player) end)
        if okExt and isExt then
            local ok, v = pcall(function() return door:isLockedByKey() end)
            return ok and v or false
        end
        return false
    end
    -- Thumpable doors / gates
    local okK, lockedKey = pcall(function() return door:isLockedByKey() end)
    if okK and lockedKey then return true end
    local okP, lockedPad = pcall(function() return door:isLockedByPadlock() end)
    if okP and lockedPad then return true end
    return false
end

-- Checks for obstructions on multi-tile gates (Thumpables)
local function getThumpObstructedAcrossSquares(thumpDoor)
    -- Checks obstructions on gates occupying multiple tiles
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
        -- E / W
        if checkSq(sq:getE()) then return true end
        if checkSq(sq:getW()) then return true end
    else
        -- N / S
        if checkSq(sq:getN()) then return true end
        if checkSq(sq:getS()) then return true end
    end
    return false
end

-- General check for door obstruction
local function doorIsObstructed(door)
    local ok, v = pcall(function() return door:isObstructed() end)
    if ok and v then return true end
    if isThumpDoor(door) then
        local ok2, v2 = pcall(getThumpObstructedAcrossSquares, door)
        if ok2 and v2 then return true end
    end
    return false
end

-- Validates if the player can interact with the door (not open, not locked, etc.)
local function canUseDoor(player, door)
    if not door or not isDoor(door) then return false end
    if doorIsOpen(door) then return false end
    if doorIsBarricaded(door) then return false end
    if doorIsLocked(player, door) then return false end
    if doorIsObstructed(door) then return false end
    return true
end

-- Generates a unique string key for a door based on position and type
local function doorKeyFrom(door)
    local sq = door:getSquare()
    if not sq then return tostring(door) end
    local north = false
    local okN, vN = pcall(function() return door:getNorth() end)
    if okN then north = vN end
    local kind = isThumpDoor(door) and "T" or "D"
    return string.format("%s:%d:%d:%d:%s", kind, sq:getX(), sq:getY(), sq:getZ(), north and "N" or "W")
end

-- Checks if a specific door key is in cooldown
local function inCooldown(key)
    local untilMs = MOD._state.cooldownUntil[key]
    return untilMs and nowMs() < untilMs
end

-- Sets a cooldown for a specific door key
local function setCooldown(key, ms)
    MOD._state.cooldownUntil[key] = nowMs() + ms
end

-- Toggles the door state (Open/Close) with compatibility fallback
local function toggleDoor(player, door)
    local ok = pcall(function() door:ToggleDoor(player) end)
    if not ok then
        -- Compatibility fallback
        pcall(function() door:toggleDoor(player) end)
    end
    pcall(function() door:update() end)
end

-- Calculates squared distance to the center of a square
local function distSqToSquareCenter(px, py, sq)
    local cx = sq:getX() + 0.5
    local cy = sq:getY() + 0.5
    local dx = px - cx
    local dy = py - cy
    return dx*dx + dy*dy
end

-- =========================================================
-- AutoClose manager (without TimedAction)
-- =========================================================
local function manhattanDistSq(a, b)
    return math.abs(a:getX() - b:getX()) + math.abs(a:getY() - b:getY())
end

-- Attempts to re-locate the door object based on stored state (square, direction)
local function findDoorNearSquare(state)
    local baseSq = state.square
    if not baseSq then return nil end

    local function scanSquare(sq)
        if not sq then return nil end
        local d1 = sq:getDoor(true)
        if d1 then return d1 end
        local d2 = sq:getDoor(false)
        if d2 then return d2 end

        -- Thumpable door scan
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
        -- For large gates, check adjacent tiles based on orientation
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
        -- For standard doors, check immediate neighbors just in case
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

-- Main loop for auto-closing doors
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
                    -- Close if MIN time passed and player is no longer adjacent
                    local distSq = distSqToSquareCenter(player:getX(), player:getY(), dsq)
                    local limitSq = AUTO_CLOSE_ADJACENT_DIST * AUTO_CLOSE_ADJACENT_DIST

                    if elapsed >= AUTO_CLOSE_MIN_DELAY_MS and distSq > limitSq then
                        toggleDoor(player, door)
                        pending[key] = nil
                        setCooldown(key, DOOR_COOLDOWN_MS)
                    end
                else
                    -- Player changed Z level or door square invalid, stop tracking
                    pending[key] = nil
                end
            else
                -- Door already closed or gone
                pending[key] = nil
            end
        end
    end
end

-- =========================================================
-- Open logic (common)
-- =========================================================
-- Handles the actual opening of the door and sets up auto-close state
local function openDoorByMod(player, door)
    local key = doorKeyFrom(door)
    if inCooldown(key) then return end
    if MOD._state.pendingClose[key] ~= nil then return end -- Already waiting for close

    toggleDoor(player, door)

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
    setCooldown(key, DOOR_COOLDOWN_MS)
end

-- =========================================================
-- RUNNING: collision handler
-- =========================================================
-- Triggered when player collides with an object (Running only)
local function onObjectCollide(obj, collided)
    local sbox = sv()
    if not sbox.WhileRunning then return end
    if not obj or not instanceof(obj, "IsoPlayer") then return end
    if _localPlayerObjIndex ~= nil and obj:getObjectIndex() ~= _localPlayerObjIndex then return end

    -- Only RUNNING (not sprinting)
    if not obj:IsRunning() then return end
    if obj:isSprinting() then return end

    if not collided or not isDoor(collided) then return end
    if not canUseDoor(obj, collided) then return end

    openDoorByMod(obj, collided)
end

-- =========================================================
-- SPRINT: probe ahead (avoids collision fall)
-- =========================================================
-- Converts IsoDirection to vector
local function dirToVector(dir)
    if dir == IsoDirections.N then return 0, -1 end
    if dir == IsoDirections.S then return 0, 1 end
    if dir == IsoDirections.E then return 1, 0 end
    if dir == IsoDirections.W then return -1, 0 end
    if dir == IsoDirections.NE then return 1, -1 end
    if dir == IsoDirections.NW then return -1, -1 end
    if dir == IsoDirections.SE then return 1, 1 end
    if dir == IsoDirections.SW then return -1, 1 end
    return 0, 0
end

-- Finds a closed, usable door on a specific square
local function findClosedDoorOnSquare(player, sq)
    if not sq then return nil end
    local d = sq:getDoor(true)
    if d and canUseDoor(player, d) then return d end
    d = sq:getDoor(false)
    if d and canUseDoor(player, d) then return d end

    -- Thumpable doors
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

-- Probes ahead of the sprinting player to open doors before collision
local function sprintProbe()
    local sbox = sv()
    if not sbox.WhileSprinting then return end
    local player = getSpecificPlayer(_localPlayerIndex or 0)
    if not player or not player:getSquare() then return end
    if not player:isSprinting() then return end

    local t = nowMs()
    if (t - (MOD._state.lastSprintProbeAt or 0)) < SPRINT_PROBE_INTERVAL_MS then return end
    MOD._state.lastSprintProbeAt = t

    local sq = player:getSquare()
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local dx, dy = dirToVector(player:getDir())

    if dx == 0 and dy == 0 then return end

    local cell = getCell()

    -- Player's real position (float)
    local px, py = player:getX(), player:getY()

    -- Normalize diagonals so "0.7" means 0.7 real tiles
    local ndx, ndy = dx, dy
    if dx ~= 0 and dy ~= 0 then
        local inv = 1 / math.sqrt(2)
        ndx, ndy = dx * inv, dy * inv
    end

    -- Optional: checking dist=0 isn't strictly necessary, but kept for safety (doors on same tile)
    for dist = 0, SPRINT_PROBE_MAX_DIST, SPRINT_PROBE_STEP_DIST do
        local tx = math.floor(px + ndx * dist)
        local ty = math.floor(py + ndy * dist)
        local testSq = cell:getGridSquare(tx, ty, z)

        local door = findClosedDoorOnSquare(player, testSq)
        if door then
            openDoorByMod(player, door)
            return
        end
    end
end

-- =========================================================
-- Events
-- =========================================================
local function OnCreatePlayer(playerIndex, player)
    _localPlayerIndex = playerIndex or 0
    if player then
        _localPlayerObjIndex = player:getObjectIndex()
    end
end

local function OnTick()
    sprintProbe()
    updateAutoClose()
end

Events.OnCreatePlayer.Add(OnCreatePlayer)
Events.OnObjectCollide.Add(onObjectCollide)
Events.OnTick.Add(OnTick)
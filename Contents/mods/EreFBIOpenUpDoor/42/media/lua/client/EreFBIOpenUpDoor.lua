-- EreFBIOpenUp Door (Build 42)
EreFBIOpenUpDoor = EreFBIOpenUpDoor or {}
local MOD = EreFBIOpenUpDoor

-- =========================================================
-- Tunables (Safe default configuration)
-- =========================================================
local RUN_PROBE_INTERVAL_MS = 60
local RUN_PROBE_STEP_DIST   = 0.1
local RUN_PROBE_MAX_DIST    = 0.5
local SPRINT_PROBE_INTERVAL_MS = 60   -- How often to check for doors while sprinting
local SPRINT_PROBE_STEP_DIST   = 0.1  -- Raycast step distance
local SPRINT_PROBE_MAX_DIST    = 0.8  -- Max distance to check ahead when sprinting
local ISO_DIR_COMPENSATION     = 0.6
local AUTO_CLOSE_MIN_DELAY_MS  = 300  -- Minimum time before auto-close triggers
local AUTO_CLOSE_ADJACENT_DIST = 1.1  -- Distance threshold to consider player "past" the door
local DOOR_COOLDOWN_MS         = 300  -- Cooldown to prevent spamming open/close
local GATE_SCAN_MAX_TILES      = 3.0    -- Max tiles to scan for multi-tile gates

local DASH_VAR         = "EreFBI_DoorDash"
local DASH_DURATION_MS = 1150
local DASH_RUN_DURATION_MULTI = 1.1
local DASH_SPRINT_DURATION_MULTI = 1.5

MOD._state = MOD._state or {
    pendingClose = {},
    cooldownUntil = {},
    lastSprintProbeAt = 0,
    lastRunProbeAt = 0,
    dashUntilByPlayer = {}
}


local _localPlayerIndex = 0
local _localPlayerObjIndex = nil

-- =========================================================
-- Helpers: Basics
-- =========================================================
-- Get current timestamp in milliseconds.
local function nowMs()
    if getTimestampMs then return getTimestampMs() end
    return os.time() * 1000
end

-- Fetch Sandbox Variables with fallback defaults.
local function sv()
    local root = SandboxVars and SandboxVars.EreFBIOpenUpDoor
    return {
        AutoCloseDoor  = (root == nil or root.AutoCloseDoor ~= false),
        EnableAnimation = (root == nil or root.EnableAnimation ~= false),
        WhileRunning   = (root == nil or root.WhileRunning ~= false),
        WhileSprinting = (root == nil or root.WhileSprinting ~= false),

        ShoveNearbyZombies = (root ~= nil and root.ShoveNearbyZombies == true),
        ShoveRange         = (root ~= nil and root.ShoveRange) or 1.8,
        ShoveAngle         = (root ~= nil and root.ShoveAngle) or 70.0,
        KnockdownChance    = (root ~= nil and root.KnockdownChance) or 25,

        EnablePropagation  = (root ~= nil and root.EnablePropagation == true),
        PropagationDepth   = (root ~= nil and root.PropagationDepth) or 1,
        PropagationStrength= (root ~= nil and root.PropagationStrength) or 60,
    }
end

-- Safe wrapper for random number generation.
local function ZombRandSafe(max)
    if ZombRand then return ZombRand(max) end
    return math.random(max)
end

-- =========================================================
-- Helpers: Geometry & Direction
-- =========================================================
-- Convert IsoDirection to a local vector (x, y).
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

-- Get the player's forward direction as a unit vector.
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

-- Get a simplified step vector (1, 0, -1) based on player facing.
local function getForwardStep(player)
    local fx, fy = getForwardUnit(player)
    local sx, sy = 0, 0
    if math.abs(fx) > 0.33 then sx = (fx > 0) and 1 or -1 end
    if math.abs(fy) > 0.33 then sy = (fy > 0) and 1 or -1 end
    return sx, sy
end

-- Calculate squared distance from point to the center of a square.
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
-- Check if object is a thumpable door (player built or specific types).
local function isThumpDoor(obj)
    return instanceof(obj, "IsoThumpable") and obj:isDoor()
end

-- Check if object is any valid door type.
local function isDoor(obj)
    return instanceof(obj, "IsoDoor") or isThumpDoor(obj)
end

-- Check if door is currently open.
local function doorIsOpen(door)
    local ok, v = pcall(function() return door:IsOpen() end)
    if ok then return v end
    ok, v = pcall(function() return door:isOpen() end)
    if ok then return v end
    return false
end

-- Check if door is barricaded.
local function doorIsBarricaded(door)
    local ok, v = pcall(function() return door:isBarricaded() end)
    if ok then return v end
    return false
end

-- Check if door is locked (key or padlock).
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

-- Check for obstructions on multi-tile thumpable doors.
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

-- Check if door is obstructed by objects or characters.
local function doorIsObstructed(door)
    local ok, v = pcall(function() return door:isObstructed() end)
    if ok and v then return true end
    if isThumpDoor(door) then
        local ok2, v2 = pcall(getThumpObstructedAcrossSquares, door)
        if ok2 and v2 then return true end
    end
    return false
end

-- Comprehensive check if a player can interact with the door.
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
-- Safely get sprite name.
local function spriteNameSafe(obj)
    local ok, sp = pcall(function() return obj:getSprite() end)
    if ok and sp then
        local ok2, name = pcall(function() return sp:getName() end)
        if ok2 then return name end
    end
    return nil
end

-- Safely get object orientation (North/West).
local function northSafe(obj, fallback)
    local ok, v = pcall(function() return obj:getNorth() end)
    if ok then return v end
    return fallback
end

-- Find a part of a multi-tile gate on a specific square that matches the base door.
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

-- Get all squares occupied by a door (handles large gates).
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
-- Check if zombie is valid for physics effects.
local function isStaggerableZombie(z)
    return z
            and instanceof(z, "IsoZombie")
            and not z:isDead()
            and not z:isKnockedDown()
end

-- Check if a zombie is within a cone behind the door relative to the player.
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

-- Apply knockdown or stagger to a zombie.
local function applyEffectToZombie(z, knockChance)
    if ZombRandSafe(100) < knockChance then
        z:setKnockedDown(true)
    else
        z:setStaggerBack(true)
    end
end

-- Recursively propagate the shove effect to zombies behind the initial targets.
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

-- Main logic to apply shove to zombies near the door.
local function applyDoorShoveLocal(player, originSquares)
    local sbox = sv()
    if not sbox.ShoveNearbyZombies then return end
    if not player or not originSquares or #originSquares == 0 then return end

    local cell = getCell()
    if not cell then return end

    local zlist = cell:getZombieList()
    if not zlist then return end

    -- =========================================================
    -- 1. Configuración de Variables
    -- =========================================================
    local range = tonumber(sbox.ShoveRange) or 1.8
    if range <= 0 then return end
    local r2 = range * range

    local angleDeg = tonumber(sbox.ShoveAngle) or 70.0
    if angleDeg < 0 then angleDeg = 0 elseif angleDeg > 180 then angleDeg = 180 end

    local knockChance = math.floor(tonumber(sbox.KnockdownChance) or 25)
    if knockChance < 0 then knockChance = 0 elseif knockChance > 100 then knockChance = 100 end

    local doProp = (sbox.EnablePropagation == true)
    local maxDepth = math.floor(tonumber(sbox.PropagationDepth) or 0)
    if maxDepth < 0 then maxDepth = 0 end

    local propStrength = math.floor(tonumber(sbox.PropagationStrength) or 0)
    if propStrength < 0 then propStrength = 0 elseif propStrength > 100 then propStrength = 100 end

    local stepX, stepY = 0, 0
    if doProp and maxDepth > 0 and propStrength > 0 then
        stepX, stepY = getForwardStep(player)
    end

    -- =========================================================
    -- 2. Sistema de Sincronización MP y Helpers Internos
    -- =========================================================
    local processed = {} -- Evitar golpear al mismo zombie dos veces
    local syncData = {}  -- Tabla para guardar los datos a enviar al servidor
    local isMultiplayer = isClient()

    -- Función interna para aplicar efecto y guardar datos
    local function applyEffectAndRecord(z, forcedAction)
        if not isStaggerableZombie(z) then return end

        local isKnock = false

        -- Determinamos si es Knock o Stagger
        if forcedAction == "knock" then
            isKnock = true
            z:setKnockedDown(true)
        elseif forcedAction == "stagger" then
            isKnock = false
            z:setStaggerBack(true)
        else
            -- Cálculo aleatorio (Autoridad del Cliente)
            if ZombRandSafe(100) < knockChance then
                z:setKnockedDown(true)
                isKnock = true
            else
                z:setStaggerBack(true)
                isKnock = false
            end
        end

        processed[z] = true

        -- Si es MP, guardamos el ID y la acción para enviarlo
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

    -- Función recursiva interna para la propagación
    local function propagateRecursive(fromZombie, currentDepth)
        if currentDepth <= 0 then return end
        if stepX == 0 and stepY == 0 then return end

        local sq = fromZombie:getSquare()
        if not sq then return end
        local c = sq:getCell()

        -- Calcular siguiente cuadro basado en la dirección del jugador
        local nextSq = c:getGridSquare(sq:getX() + stepX, sq:getY() + stepY, sq:getZ())
        if not nextSq then return end

        local mobs = nextSq:getMovingObjects()
        if not mobs then return end

        local nextCarrier = nil

        for i = 0, mobs:size() - 1 do
            local other = mobs:get(i)
            if isStaggerableZombie(other) and not processed[other] then
                -- Tiramos dados de propagación
                if ZombRandSafe(100) < propStrength then
                    applyEffectAndRecord(other, nil) -- nil para que calcule knockChance normal
                    if not nextCarrier then nextCarrier = other end
                end
            end
        end

        if nextCarrier then
            propagateRecursive(nextCarrier, currentDepth - 1)
        end
    end

    -- =========================================================
    -- 3. Ejecución Principal (Zombies en la Puerta)
    -- =========================================================
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

                    -- Chequeo de distancia y ángulo
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

    -- =========================================================
    -- 4. Ejecución de Propagación (Zombies detrás)
    -- =========================================================
    if #carriers > 0 then
        for _, c in ipairs(carriers) do
            propagateRecursive(c, maxDepth)
        end
    end

    -- =========================================================
    -- 5. Envío de Comando al Servidor
    -- =========================================================
    if isMultiplayer and #syncData > 0 then
        sendClientCommand(player, "EreFBI", "ZombieShoveSync", { zombies = syncData })
    end
end

-- Entry point for requesting a door shove action.
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
-- Generate a unique key for a door based on its properties and location.
local function doorKeyFrom(door)
    local sq = door:getSquare()
    if not sq then return tostring(door) end
    local north = false
    local okN, vN = pcall(function() return door:getNorth() end)
    if okN then north = vN end
    local kind = isThumpDoor(door) and "T" or "D"
    return string.format("%s:%d:%d:%d:%s", kind, sq:getX(), sq:getY(), sq:getZ(), north and "N" or "W")
end

-- Check if a door is currently in cooldown.
local function inCooldown(key)
    local untilMs = MOD._state.cooldownUntil[key]
    return untilMs and nowMs() < untilMs
end

-- Set cooldown for a door.
local function setCooldown(key, ms)
    MOD._state.cooldownUntil[key] = nowMs() + ms
end

-- =========================================================
-- Door dash (animset selector) - run/sprint
-- =========================================================
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

local function setDashVar(player, value)
    pcall(function() player:setVariable(DASH_VAR, value) end)
end

local function getDashKey(player)
    return tostring(player:getObjectIndex() or player)
end

local function triggerDoorDashAnim(player)
    if not player then return end
    local t = nowMs()
    local k = getDashKey(player)

    local untilMs = MOD._state.dashUntilByPlayer[k]
    if untilMs and t < untilMs then
        return -- ya está en dash, no re-dispares
    end

    -- Si jugador sprint utilizar DASH_DURATION_MS / DASH_SPRINT_DURATION_MULTI si es running / DASH_RUN_DURATION_MULTI
    local durationMs = DASH_DURATION_MS
    if player:IsRunning() then
        durationMs = durationMs / DASH_RUN_DURATION_MULTI
    elseif player:isSprinting() then
        durationMs = durationMs / DASH_SPRINT_DURATION_MULTI
    end

    -- asegúrate que entra limpio
    setDashVar(player, true)
    MOD._state.dashUntilByPlayer[k] = t + durationMs
end

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
-- Toggle the door state (Open/Close).
local function toggleDoor(player, door)
    local ok = pcall(function() door:ToggleDoor(player) end)
    if not ok then
        pcall(function() door:toggleDoor(player) end)
    end
    pcall(function() door:update() end)
end

-- Handle the "Open Up" action: open door, shove zombies, track state.
local function openDoorByMod(player, door)
    local key = doorKeyFrom(door)
    if inCooldown(key) then return end
    if MOD._state.pendingClose[key] ~= nil then return end

    -- LEEMOS LAS OPCIONES AQUÍ
    local sbox = sv()

    -- SOLO DISPARAMOS LA ANIMACIÓN SI ESTÁ ACTIVADA
    if sbox.EnableAnimation then
        triggerDoorDashAnim(player)
    end

    delayTicks(1, function()
        toggleDoor(player, door)
        requestDoorShove(player, door)

        local sbox = sv()
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
-- Find the door object again based on stored state (in case object ref changed).
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

-- Update loop for auto-closing doors after the player passes through.
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
-- Handler for collision events (Running into doors).
local function onObjectCollide(obj, collided)
    return
end

-- Find a closed, usable door on a specific square.
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

local function runProbe()
    local sbox = sv()
    if not sbox.WhileRunning then return end

    local player = getSpecificPlayer(_localPlayerIndex or 0)
    if not player or not player:getSquare() then return end

    -- Si ya estamos en dash, evitamos solapar acciones
    if player and player:getVariableBoolean("EreFBI_DoorDash") then return end

    if player:isSprinting() then return end
    if not player:IsRunning() then return end

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

    -- =========================================================
    -- LÓGICA DE COMPENSACIÓN ISOMÉTRICA (Aplicada a Run)
    -- =========================================================
    local currentMaxDist = RUN_PROBE_MAX_DIST

    -- Si vamos hacia direcciones positivas (Sur/Este), extendemos el alcance
    -- para detectar la puerta que técnicamente reside en la siguiente casilla.
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

-- Raycast probe for sprinting (opens doors slightly before collision).
local function sprintProbe()
    local sbox = sv()
    if not sbox.WhileSprinting then return end

    local player = getSpecificPlayer(_localPlayerIndex or 0)
    if not player or not player:getSquare() then return end

    -- Si ya estamos en dash, no hacemos nada
    if player:getVariableBoolean("EreFBI_DoorDash") then return end

    if not player:isSprinting() then return end

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
-- Initialize local player index.
local function OnCreatePlayer(playerIndex, player)
    _localPlayerIndex = playerIndex or 0
    if player then
        _localPlayerObjIndex = player:getObjectIndex()
    end
end

-- Main tick loop.
local function OnTick()
    updateDoorDashAnim()
    runProbe()
    sprintProbe()
    updateAutoClose()
end

local function OnServerCommand(module, command, args)
    if module ~= "EreFBI" then return end

    if command == "SyncShove" and args and args.zombies then
        local zombiesToUpdate = args.zombies

        -- Buscamos los zombies en NUESTRA lista local
        -- Project Zomboid no tiene una forma super rápida de buscar por ID en Lua
        -- así que iteramos la lista de zombies cargados.
        local cell = getCell()
        if not cell then return end
        local zlist = cell:getZombieList()

        -- Mapeamos IDs recibidos para acceso rápido
        local targetZombies = {}
        for _, data in ipairs(zombiesToUpdate) do
            targetZombies[data.id] = data.action
        end

        for i = 0, zlist:size() - 1 do
            local z = zlist:get(i)
            local id = z:getOnlineID()

            -- Si este zombie está en la lista que mandó el servidor
            if id ~= -1 and targetZombies[id] then
                local action = targetZombies[id]

                -- Aplicamos el efecto sin calcular RNG, usamos el que decidió el Cliente A
                if action == "knock" then
                    z:setKnockedDown(true)
                else
                    z:setStaggerBack(true)
                end

                -- Remover de la lista para optimizar (opcional)
                targetZombies[id] = nil
            end
        end
    end
end

Events.OnServerCommand.Add(OnServerCommand)
Events.OnCreatePlayer.Add(OnCreatePlayer)
Events.OnObjectCollide.Add(onObjectCollide)
Events.OnTick.Add(OnTick)

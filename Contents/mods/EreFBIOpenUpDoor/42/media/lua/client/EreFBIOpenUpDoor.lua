-- Ere FBI Open Up Door
-- Author: EremesNG
-- Version: 1.42

local MOD_ID = "EreFBIOpenUpDoor"
local CLOSE_DELAY = 13

EreFBIOpenUpDoor = EreFBIOpenUpDoor or {}

local function getOpts()
    local sv = SandboxVars and SandboxVars[MOD_ID]
    return sv or {}
end

local function isLocalPlayer(playerObj)
    if not playerObj or not instanceof(playerObj, "IsoPlayer") then return false end

    -- Preferido si existe en tu build:
    if playerObj.isLocalPlayer then
        local ok, val = pcall(playerObj.isLocalPlayer, playerObj)
        if ok then return val end
    end

    -- Fallback splitscreen:
    if playerObj.getPlayerNum then
        local pn = playerObj:getPlayerNum()
        local lp = getSpecificPlayer(pn)
        return lp ~= nil and lp == playerObj
    end

    -- Último fallback:
    return playerObj == getPlayer()
end

local function isThumpDoor(obj)
    return obj and instanceof(obj, "IsoThumpable") and obj.isDoor and obj:isDoor()
end

local function isDoor(obj)
    return obj and (instanceof(obj, "IsoDoor") or isThumpDoor(obj))
end

local function safeBoolCall(obj, fnName, ...)
    if not obj or not obj[fnName] then return false end
    local ok, val = pcall(obj[fnName], obj, ...)
    return ok and val == true
end

local function isBarricaded(door)
    return safeBoolCall(door, "isBarricaded")
end

local function isLocked(character, door)
    -- En pro: si está locked-by-key, no auto-abrir (sea interior/exterior)
    if safeBoolCall(door, "isLockedByKey") then return true end
    if safeBoolCall(door, "isLockedByPadlock") then return true end

    -- Fallback legacy: exteriorDoor + lockedByKey
    if instanceof(door, "IsoDoor") and door.isExteriorDoor then
        local ok, ext = pcall(door.isExteriorDoor, door, character)
        if ok and ext and safeBoolCall(door, "isLockedByKey") then
            return true
        end
    end

    return false
end

local function gateNeighborsObstructed(thumpDoor)
    local sq = thumpDoor and thumpDoor.getSquare and thumpDoor:getSquare()
    if not sq then return false end

    local north = safeBoolCall(thumpDoor, "getNorth") or (thumpDoor.getNorth and thumpDoor:getNorth()) or false

    if north then
        local e = sq:getE()
        local w = sq:getW()
        local dE = e and e:getDoor(true) or nil
        local dW = w and w:getDoor(true) or nil
        if dE and safeBoolCall(dE, "isObstructed") then return true end
        if dW and safeBoolCall(dW, "isObstructed") then return true end
    else
        local n = sq:getN()
        local s = sq:getS()
        local dN = n and n:getDoor(false) or nil
        local dS = s and s:getDoor(false) or nil
        if dN and safeBoolCall(dN, "isObstructed") then return true end
        if dS and safeBoolCall(dS, "isObstructed") then return true end
    end

    return false
end

local function isObstructed(door)
    if safeBoolCall(door, "isObstructed") then return true end
    if isThumpDoor(door) then
        return gateNeighborsObstructed(door)
    end
    return false
end

local function shouldAutoOpen(playerObj, opts)
    local runningOk = opts.WhileRunning and playerObj.IsRunning and playerObj:IsRunning()
    local sprintOk  = opts.WhileSprinting and playerObj.isSprinting and playerObj:isSprinting()
    return runningOk or sprintOk
end

local function onObjectCollide(character, collider)
    if not isLocalPlayer(character) then return end

    local opts = getOpts()
    if not shouldAutoOpen(character, opts) then return end
    if not isDoor(collider) then return end

    if isBarricaded(collider) then return end
    if isLocked(character, collider) then return end
    if isObstructed(collider) then return end

    if collider.IsOpen and not collider:IsOpen() then
        collider:ToggleDoor(character)
        if collider.update then collider:update() end

        if opts.AutoCloseDoor then
            local sq = collider.getSquare and collider:getSquare() or nil
            local north = collider.getNorth and collider:getNorth() or false
            ISTimedActionQueue.add(
                TAEreFBIOpenUpDoor:new(character, collider, sq, isThumpDoor(collider), north, CLOSE_DELAY)
            )
        end
    end
end

Events.OnObjectCollide.Add(onObjectCollide)
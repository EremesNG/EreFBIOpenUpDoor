-- Ere FBI Open Up Door
-- Author: EremesNG
-- Version: 1

local _localPlayerObject;


-- Get local player for comparison.
local function OnCreatePlayer(playerID, player)

    _localPlayerObject = player:getObjectIndex();

end

-- If the character is sprinting and enters a collision chech for a door
function fbiopenupdoor(character, collider)
    -- Check if this is a collision for the current player.
    if instanceof(character, 'IsoPlayer') and (character:isSprinting() or character:IsRunning() ) then
        -- Check if this is a collision with a window.
        if instanceof(collider, 'IsoDoor') or isEreThumbDoor(collider) then
            -- Door isn't barricaded, isn't LockedNyKey, isn't Obstructed.
            if not collider:isBarricaded() and not collider:isLockedByKey() and not EreObs(collider) then
                -- Open the door if closed
                if not collider:IsOpen() then
                    collider:ToggleDoor(character);
                    collider:update();
                    if(SandboxVars.EreFBIOpenUpDoor.AutoCloseDoor) then
                        ISTimedActionQueue.add(TAEreFBIOpenUpDoor:new(character, collider, collider:getSquare(), isEreThumbDoor(collider), collider:getNorth(), 13));
                    end
                end
            end
            return;
        end
    end
end

-- To know if the door is obstructed, in case of gate we need to compare NSWE+ because every square have his own
function EreObs(collider)
    if (collider:isObstructed()) then return true end
    if not (isEreThumbDoor(collider)) then
        return collider:isObstructed();
    else
        local sts, obsval = pcall(EreGetTumpObs, collider);
        if (sts) then
            return obsval;
        else
            return collider:isObstructed();
        end
    end
    return false;
end

-- Mitigate other mods converting door to thumpables and the crafted ones
function EreGetTumpObs(collider)
    local sq = collider:getSquare();
    if (collider:getNorth()) then
        local tNE = sq:getE();
        if not (tNE == nil) then
            tNE = sq:getE():getDoor(collider:getNorth());
        end
        local tNW = sq:getW();
        if not (tNE == nil) then
            tNW = sq:getW():getDoor(collider:getNorth());
        end
        if not (tNE == nil) then
            if (tNE:isObstructed()) then
                return true;
            end 
        end
        if not (tNW == nil) then 
            if (tNW:isObstructed()) then 
                return true;
            end 
        end
    else
        local tSN = sq:getN();
        if not (tSN == nil) then
            tSN = sq:getN():getDoor(collider:getNorth());
        end
        local tSS = sq:getS();
        if not (tSS == nil) then
            tSS = sq:getS():getDoor(collider:getNorth());
        end
        if not (tSN == nil) then 
            if (tSN:isObstructed()) then 
                return true;
            end 
        end
        if not (tSS == nil) then 
            if (tSS:isObstructed()) then 
                return true;
            end 
        end
    end
end


-- To know if is a gate
function isEreThumbDoor(collider)
    if(instanceof(collider, 'IsoThumpable')) then
        return collider:isDoor()
    end
    return false
end

-- Save a ref to the player objectIndex on player creation.
Events.OnCreatePlayer.Add(OnCreatePlayer)

-- Check on every character/object collision.
Events.OnObjectCollide.Add(fbiopenupdoor);
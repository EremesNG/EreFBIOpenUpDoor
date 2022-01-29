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
            -- Door isn't barricaded.
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

function EreObs(collider)
    if (collider:isObstructed()) then return true end
    if not (isEreThumbDoor(collider)) then
        return collider:isObstructed();
    else
        local thumpObs = collider:isObstructed();
        local sq = collider:getSquare();
        if (collider:getNorth()) then
            local tNE = sq:getE():getDoor(true);
            local tNW = sq:getW():getDoor(true);
            if not (tNE == nil) then if (tNE:isObstructed()) then return true end end
            if not (tNW == nil) then if (tNW:isObstructed()) then return true end end
        else
            local tSN = sq:getN():getDoor(true);
            local tSS = sq:getS():getDoor(true);
            if not (tSN == nil) then if (tSN:isObstructed()) then return true end end
            if not (tSS == nil) then if (tSS:isObstructed()) then return true end end
        end
    end
    return false;
end


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
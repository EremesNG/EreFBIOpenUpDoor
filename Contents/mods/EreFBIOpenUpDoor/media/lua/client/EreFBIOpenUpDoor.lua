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
        if instanceof(collider, 'IsoDoor') then
            -- Door isn't barricaded.
            if not collider:isBarricaded() and not collider:isLockedByKey() then
                -- Open the door if closed
                if not collider:IsOpen() then
                    collider:ToggleDoor(character);
                    if(SandboxVars.EreFBIOpenUpDoor.AutoCloseDoor) then
                        ISTimedActionQueue.add(TAEreFBIOpenUpDoor:new(character, collider, 10));
                    end
                end
            end
            return;
        end
    end
end


-- Save a ref to the player objectIndex on player creation.
Events.OnCreatePlayer.Add(OnCreatePlayer)

-- Check on every character/object collision.
Events.OnObjectCollide.Add(fbiopenupdoor);
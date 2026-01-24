require "TimedActions/ISBaseTimedAction"

TAEreFBIOpenUpDoor = ISBaseTimedAction:derive("TAEreFBIOpenUpDoor")

function TAEreFBIOpenUpDoor:findGateDoor()
    local sq = self.square
    if not sq then return nil, nil end

    local cur = sq
    for i = 0, 3 do
        local door = cur and cur:getDoor(self.north) or nil
        if door then return cur, door end

        if i == 3 or not cur then break end
        cur = self.north and cur:getE() or cur:getN()
    end

    return nil, nil
end

function TAEreFBIOpenUpDoor:isValid()
    if not self.character or (self.character.isDead and self.character:isDead()) then return false end
    if not self.item then return false end

    if self.thumpable then
        local _, door = self:findGateDoor()
        return door ~= nil and door.IsOpen and door:IsOpen()
    end

    return self.item.IsOpen and self.item:IsOpen()
end

function TAEreFBIOpenUpDoor:start()
    -- sin animación / sin progress bar (ok)
end

function TAEreFBIOpenUpDoor:stop()
    ISBaseTimedAction.stop(self)
end

function TAEreFBIOpenUpDoor:perform()
    if not self:isValid() then
        ISBaseTimedAction.perform(self)
        return
    end

    if self.thumpable then
        local _, door = self:findGateDoor()
        if door and door.IsOpen and door:IsOpen() then
            door:ToggleDoor(self.character)
        end
    else
        if self.item.IsOpen and self.item:IsOpen() then
            self.item:ToggleDoor(self.character)
        end
    end

    ISBaseTimedAction.perform(self)
end

function TAEreFBIOpenUpDoor:new(character, item, square, thumpable, north, time)
    local o = ISBaseTimedAction.new(self, character)
    o.item = item
    o.square = square
    o.thumpable = thumpable == true
    o.north = north == true

    o.useProgressBar = false
    o.stopOnWalk = false
    o.stopOnRun = false
    o.stopOnAim = false
    o.maxTime = time or 13

    return o
end

function TAEreFBIOpenUpDoor:adjustMaxTime(maxTime)
    return maxTime
end

function TAEreFBIOpenUpDoor:isValidStart()
    return self:isValid()
end

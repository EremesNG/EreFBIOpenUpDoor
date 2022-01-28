require "TimedActions/ISBaseTimedAction"

TAEreFBIOpenUpDoor = ISBaseTimedAction:derive("TAEreFBIOpenUpDoor");

function TAEreFBIOpenUpDoor:isValid()
	return true;
end

function ISOpenCloseDoor:update()
	--self.character:faceThisObject(self.item)
end

-- Start action
function TAEreFBIOpenUpDoor:start()
end

function TAEreFBIOpenUpDoor:stop()
    print("EREMES TIMED ACTION STOP");
    ISBaseTimedAction.stop(self);
end

-- Perform attack
function TAEreFBIOpenUpDoor:perform()
    print("EREMES TIMED ACTION PERFORM");
    if self.item:IsOpen() then
        print("EREMES TIMED ACTION TOGGLE");
        self.item:ToggleDoor(self.character);
    end
    ISBaseTimedAction.perform(self);
end


-- Set up timed action variables
function TAEreFBIOpenUpDoor:new(character, item, time)
	local o = {}
	setmetatable(o, self)
	self.__index = self
	o.character = character;
	o.item = item;
    print("EREMES TIMED ACTION");
	print(item);
    o.useProgressBar = false;
	o.stopOnWalk = false;
	o.stopOnRun = false;
	o.maxTime = time;
	return o;
end

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
    ISBaseTimedAction.stop(self);
end

-- Perform attack
function TAEreFBIOpenUpDoor:perform()
	-- Save square to compare
	local cSq = self.square;
	local _cSq = cSq;
	-- In case of gate we need to compare the NSWE++ squares cause when opened they change
	if (self.thumpable) then
		for i = 1, 3, 1
		do
			if(self.north) then
				_cSq = _cSq:getE();
			else
				_cSq = _cSq:getN();
			end
			if not (_cSq == nil) then
				if not (_cSq:getDoor(self.north) == nil) then
					cSq = _cSq;
					break;
				else
					break;
				end
			else
				break;
			end
		end
		if cSq:getDoor(self.north):IsOpen() then
			cSq:getDoor(self.north):ToggleDoor(self.character);
		else
			self:stop();
		end
	else
		if self.item:IsOpen() then
			self.item:ToggleDoor(self.character);
		else
			self:stop();
		end
	end
    ISBaseTimedAction.perform(self);
end


-- Set up timed action variables
function TAEreFBIOpenUpDoor:new(character, item, square, thumpable, north, time)
	local o = {}
	setmetatable(o, self)
	self.__index = self
	o.character = character;
	o.item = item;
	o.square = square;
	o.thumpable = thumpable;
	o.north = north;
    --print("EREMES TIMED ACTION");
	--print(item);
    o.useProgressBar = false;
	o.stopOnWalk = false;
	o.stopOnRun = false;
	o.maxTime = time;
	return o;
end

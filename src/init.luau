--!strict
--!native

-- This implementation of the Janitor uses a stack-based order when operating with a cleanup handlers.

type Proc = () -> ()
export type JanitorImpl<Key> = {
    __index: JanitorImpl<Key>,
    __tostring: () -> "Janitor",

    add: (
        self: Janitor<Key>,
        object: { [Key]: (...any) -> ...any },
        methodName: string,
        key: Key?
    ) -> (),

    addFunction: (self: Janitor<Key>, func: Proc, key: Key?) -> (),

    clean: (self: Janitor<Key>, key: Key) -> (),

    remove: (self: Janitor<Key>, key: Key) -> (),

    cleanup: (self: Janitor<Key>) -> (),

    destroy: (self: Janitor<Key>) -> (),

    addRace: (
        self: Janitor<Key>,
        setup: (winRace: Proc) -> Proc,
        onCleanup: Proc,
        key: Key?
    ) -> Key,

    -- TODO: implement
    -- addConnectionHandler: (
    --     self: Janitor<Key>,
    --     signal: RBXScriptSignal,
    --     handler: (Key) -> (),
    --     key: Key?
    -- ) -> (RBXScriptConnection, Key),
}

export type Janitor<Key> = typeof(setmetatable({} :: {}, {} :: JanitorImpl<Key>))

type JanitorItem = Proc | false

local stack = {} :: {
    [Janitor<unknown>]: { JanitorItem },
}

local function pushStack(self: Janitor<unknown>, func: Proc): number
    local this = stack[self]
    if not this then
        this = {}
        stack[self] = this
    end

    local index = #this + 1
    this[index] = func

    return index
end

-- Basically utilizes the "table.insert" function to increase the speed in cases when
-- there is no need to know about the index at which the cleanup function was insterted.
local function pushStackNoReturn(self: Janitor<unknown>, func: Proc)
    local this = stack[self]
    if not this then
        this = {}
        stack[self] = this
    end

    table.insert(this, func)
end

local indices = {} :: {
    [Janitor<unknown>]: {
        [unknown]: Proc,
    },
}

local function pushIndice(self: Janitor<unknown>, key: unknown, func: Proc)
    local this = indices[self]
    if not this then
        this = {}
        indices[self] = this
    end

    this[key] = func
end

local JanitorImpl = {} :: JanitorImpl<any>
JanitorImpl.__index = JanitorImpl

function JanitorImpl.__tostring()
    return "Janitor"
end

local funcToIndexMap: { [Proc]: number } = {}

--[[
    Supposed to be used with Instances/tables.

    Basic usage:

    local janitor = Janitor.new()

    janitor:add(connection, "Disconnect")
    -- The equivalent is:
    janitor:addFunction(function()
        connection:Disconnect()
    end)

    janitor:add(instance, "Destroy")
    -- The equivalent is:
    janitor:addFunction(function()
        instance:Destroy()
    end)
]]

function JanitorImpl:add(object, methodName, key)
    self:addFunction(function()
        object[methodName](object)
    end, key)
end

function JanitorImpl:addFunction(func, key)
    if key then
        self:clean(key)

        funcToIndexMap[func] = pushStack(self, func)

        pushIndice(self, key, func)
    else
        pushStackNoReturn(self, func)
    end
end

-- Cleans a specific task, also replaces the JanitorItem in-place in a stack from a function to a value 'false'.
function JanitorImpl:clean(key)
    local this = indices[self]
    if this then
        local func = this[key]
        if func then
            func()

            -- Basically marking down as the one that should be ignored in the future
            -- so we preserve the same ordering without expensive remove operations;
            stack[self][funcToIndexMap[func]] = false

            funcToIndexMap[func] = nil

            this[key] = nil
        end
    end
end

function JanitorImpl:remove(key)
    local this = indices[self]
    if this then
        local func = this[key]
        if func then
            stack[self][funcToIndexMap[func]] = false

            funcToIndexMap[func] = nil

            this[key] = nil
        end
    end
end

function JanitorImpl:cleanup()
    local this = stack[self]
    if this then
        local func: JanitorItem

        for index = #this, 1, -1 do
            func = this[index]
            if func then
                funcToIndexMap[func] = nil

                func()
            end

            this[index] = nil
        end

        stack[self] = nil
    end

    indices[self] = nil
end

--[[
	This method allows to reduce a boilerplate code required for the conditional
	behavior based on the execution order of two functions.
	
	The "setup" function must return a function that will be executed in case it looses the race.
	
    
	So usually when we want to achieve this behavior, we would do something like this:
	
	local janitor = Janitor.new()
	
	-- Manually introduce a key to keep track of the cleanup function.
	local cleanupKey = {}
	
	local thread = task.delay(5, function()
		janitor:remove(cleanupKey)

		doOneTimeAction()
		doMainAction()
	end)
	
	-- In case if the signal was not fired during the delay time, we have to cleanup
    -- no longer needed thread.
	janitor:addFunction(function()
		task.cancel(thread)

		doMainAction()
	end, cleanupKey)
	
	ListenContidionChangeSignal:connect(function()
		janitor:destroy()
	end)
	
	
	
	
	Usage:
	
	local janitor = Janitor.new()
	
	local cleanupKey = janitor:addRace(function(winRace)
		local thread = task.delay(5, function()
            -- Ensure the cleanup function will not be called
			winRace()

			doOneTimeAction()
			doMainAction()
		end)
		
		return function()
			task.cancel(thread)
		end
	end, function()
		doMainAction()
	end, optionalOverrideKey)
	
	ListenContidionChangeSignal:connect(function()
		janitor:Destroy()
	end)
]]
function JanitorImpl:addRace(setup, onCleanup, key)
    if not key then
        key = {}
    end

    local isRaceEnded = false

    local function winRace()
        if isRaceEnded then
            error(
                '\n\tUnable to win the race as the "clean" function has already been called.'
                    .. '\n\tDid you forget to disconnect the race handler by using "winRace" function?',
                2
            )
        end

        isRaceEnded = true
        self:remove(key)
    end

    local onRaceLoss = setup(winRace)

    self:addFunction(function()
        isRaceEnded = true
        onRaceLoss()
        onCleanup()
    end, key)

    return key
end

--[[
	There is one repetative pattern that's often being implemented
	with the additional lines of code that should be provided by the library,
	here are few examples:
	
	Example #1 without the syntax sugar:
	
	-- A janitor that get's cleaned up everytime the MovementState switches from the Crouching one.
	local crouchingJanitor = self.crouchingJanitor
	local markerReachedSignal = self.crouchAnimationTrack:GetMarkerReachedSignal("Step")
	
	-- While we are crouching, the footstep sound will play on the "Step" keyframe.
	crouchingJanitor:add(markerReachedSignal:Connect(function()
		local removePreviousFootstepSound = FootstepsSoundManager:playMaterialSound()
		
		-- We have to manually introduce a unique key, so we can cleanup only the specific task.
		local footstepSoundKey = {}
		
		-- Ensure that when the player stepped next time, the previous footstep sound is destroyed.
		local stepConnection = markerReachedSignal:Once(function()
			print('"Step" animation Keyframe has been reached!')
			
			crouchingJanitor:remove(footstepSoundKey)
            
			removePreviousFootstepSound()
		end)
		
		-- In case the foostep sound started to play but the MovementState changed to something else,
		we also want to destroy the previous footstep sound.
		crouchingJanitor:addFunction(function()
			warn('"Crouching" state was switched to something else while we were \
				listening for the next "Step" Keyframe to play')
			stepConnection:Disconnect()
            
			removePreviousFootstepSound()
		end, footstepSoundKey)
	end), "Disconnect")
	
	
	Example #1 with a syntax sugar:
	
	local crouchingJanitor = self.crouchingJanitor
	local markerReachedSignal = self.crouchAnimationTrack:GetMarkerReachedSignal("Step")
	crouchingJanitor:add(markerReachedSignal:Connect(function()
		local removePreviousFootstepSound = FootstepsSoundManager:playMaterialSound()
		
		-- This syntax means that the provided connection will be disconnected
		-- automatically by the Janitor when it get's destroyed,
		-- as well as the "handler" function will be called after that.
		local stepConnection, optionalKeyForFurtherHandlersChain = crouchingJanitor:addConnectionHandler(
			markerReachedSignal.Once,
			function(removeKey)
				print('"Step" animation Keyframe has been reached!')
				
				return function()
					removeKey()
				
					removePreviousFootstepSound()
				end
			end),
			function()
				warn('"Crouching" state was switched to something else while we were \
					listening for the next "Step" Keyframe to play')
				
				removePreviousFootstepSound()
			end, -- optionalKey -- that one will be used instead of the generated one
		)
	end), "Disconnect")
	
	
	
	
	
	
	
	Example #2, more complex one
	
	-- A janitor that ensures our objects live no longer than the Humanoid instace.
	local humanoidAliveJanitor = self.humanoidAliveJanitor
	
	-- A janitor that lives no longer than the MovementState.Sliding
	local slidingJanitor = self.slidingJanitor
	
	slidingJanitor:addFunction(self:attachSlidingVisualHandler())
	
	-- Here we want to ensure that even after the slidingJanitor got cleaned up,
	-- we still can perform some action.
	local oneTimeConnection = someSignalWeUseToRunHandler:Once(function()
	end)
	
	
]]
-- TODO: implement the connections race method

function JanitorImpl:destroy()
    self:cleanup()

    -- Ensure no further method calls can be done
    setmetatable((self :: any) :: {}, nil)
end

local JanitorLib = {}
JanitorLib.prototype = JanitorImpl

function JanitorLib.is(value)
    return type(value) == "table" and getmetatable(value) == JanitorImpl
end

function JanitorLib.new<Key>(): Janitor<Key>
    local self = setmetatable({}, JanitorImpl)

    return self
end

return JanitorLib

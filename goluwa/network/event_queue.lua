local event_queue = {}
event_queue.EVENT = {
	CONNECT = "connect",
	DISCONNECT = "disconnect",
	RECEIVE = "receive",
}
local Event = {}
Event.__index = Event

function Event.New(event_type, peer, data)
	local self = setmetatable({}, Event)
	self.event_type = event_type
	self.peer = peer
	self.data = data or {}
	self.timestamp = os.clock()
	return self
end

local EventQueue = {}
EventQueue.__index = EventQueue

function EventQueue.New()
	local self = setmetatable({}, EventQueue)
	self.queue = {}
	self.count = 0
	return self
end

function EventQueue:Push(event)
	self.queue[#self.queue + 1] = event
	self.count = self.count + 1
end

function EventQueue:Pop()
	if #self.queue == 0 then return nil end

	local event = self.queue[1]
	table.remove(self.queue, 1)
	self.count = self.count - 1
	return event
end

function EventQueue:Peek()
	if #self.queue == 0 then return nil end

	return self.queue[1]
end

function EventQueue:IsEmpty()
	return #self.queue == 0
end

function EventQueue:GetSize()
	return #self.queue
end

function EventQueue:Clear()
	self.queue = {}
	self.count = 0
end

function EventQueue:Process(connect_cb, disconnect_cb, receive_cb)
	while not self:IsEmpty() do
		local event = self:Pop()

		if event.event_type == event_queue.EVENT.CONNECT and connect_cb then
			connect_cb(event.peer, event.data)
		elseif event.event_type == event_queue.EVENT.DISCONNECT and disconnect_cb then
			disconnect_cb(event.peer, event.data)
		elseif event.event_type == event_queue.EVENT.RECEIVE and receive_cb then
			receive_cb(event.peer, event.data.payload, event.data.channel)
		end
	end
end

event_queue.Event = Event
event_queue.EventQueue = EventQueue

function event_queue.CreateQueue()
	return EventQueue.New()
end

return event_queue

-- Tests for event queue (Step 6)

local T = import("test/environment.lua")
local event_queue = import("goluwa/network/event_queue.lua")

T.Test("Event types are defined", function()
	T(event_queue.EVENT.CONNECT)["=="]("connect")
	T(event_queue.EVENT.DISCONNECT)["=="]("disconnect")
	T(event_queue.EVENT.RECEIVE)["=="]("receive")
end)

T.Test("Event structure stores type, peer, and data", function()
	local peer = {id = 1}
	local event = event_queue.Event.New(event_queue.EVENT.CONNECT, peer, {reason = "hello"})

	T(event.event_type)["=="]("connect")
	T(event.peer)["=="](peer)
	T(event.data.reason)["=="]("hello")
	T(event.timestamp)["~="](nil)
end)

T.Test("EventQueue:Push adds event to queue", function()
	local queue = event_queue.CreateQueue()
	local event = event_queue.Event.New(event_queue.EVENT.CONNECT, nil)

	queue:Push(event)
	T(queue:GetSize())["=="](1)
	T(queue:IsEmpty())["=="](false)
end)

T.Test("EventQueue:Pop removes and returns first event", function()
	local queue = event_queue.CreateQueue()
	local event1 = event_queue.Event.New(event_queue.EVENT.CONNECT, nil)
	local event2 = event_queue.Event.New(event_queue.EVENT.RECEIVE, nil)

	queue:Push(event1)
	queue:Push(event2)

	local popped = queue:Pop()
	T(popped)["=="](event1)
	T(queue:GetSize())["=="](1)
end)

T.Test("EventQueue:Pop returns nil when empty", function()
	local queue = event_queue.CreateQueue()
	local popped = queue:Pop()
	T(popped)["=="](nil)
end)

T.Test("EventQueue:Peek returns first event without removing", function()
	local queue = event_queue.CreateQueue()
	local event = event_queue.Event.New(event_queue.EVENT.CONNECT, nil)

	queue:Push(event)
	local peeked = queue:Peek()
	T(peeked)["=="](event)
	T(queue:GetSize())["=="](1) -- Still in queue
end)

T.Test("EventQueue:Peek returns nil when empty", function()
	local queue = event_queue.CreateQueue()
	local peeked = queue:Peek()
	T(peeked)["=="](nil)
end)

T.Test("EventQueue:IsEmpty returns true for empty queue", function()
	local queue = event_queue.CreateQueue()
	T(queue:IsEmpty())["=="](true)
end)

T.Test("EventQueue:IsEmpty returns false after push", function()
	local queue = event_queue.CreateQueue()
	queue:Push(event_queue.Event.New(event_queue.EVENT.CONNECT, nil))
	T(queue:IsEmpty())["=="](false)
end)

T.Test("EventQueue:Clear removes all events", function()
	local queue = event_queue.CreateQueue()
	queue:Push(event_queue.Event.New(event_queue.EVENT.CONNECT, nil))
	queue:Push(event_queue.Event.New(event_queue.EVENT.RECEIVE, nil))

	queue:Clear()
	T(queue:GetSize())["=="](0)
	T(queue:IsEmpty())["=="](true)
end)

T.Test("EventQueue:Process calls connect callback", function()
	local queue = event_queue.CreateQueue()
	local peer = {id = 1}
	local connected = false

	queue:Push(event_queue.Event.New(event_queue.EVENT.CONNECT, peer))

	queue:Process(
		function(p, data) connected = true end, -- connect_cb
		nil,                                     -- disconnect_cb
		nil                                      -- receive_cb
	)

	T(connected)["=="](true)
end)

T.Test("EventQueue:Process calls disconnect callback", function()
	local queue = event_queue.CreateQueue()
	local peer = {id = 1}
	local disconnected = false

	queue:Push(event_queue.Event.New(event_queue.EVENT.DISCONNECT, peer))

	queue:Process(
		nil,                                     -- connect_cb
		function(p, data) disconnected = true end, -- disconnect_cb
		nil                                      -- receive_cb
	)

	T(disconnected)["=="](true)
end)

T.Test("EventQueue:Process calls receive callback with payload", function()
	local queue = event_queue.CreateQueue()
	local peer = {id = 1}
	local received_payload = nil
	local received_channel = nil

	queue:Push(event_queue.Event.New(event_queue.EVENT.RECEIVE, peer, {
		payload = "hello world",
		channel = 0,
	}))

	queue:Process(
		nil,                                     -- connect_cb
		nil,                                     -- disconnect_cb
		function(p, payload, channel)           -- receive_cb
			received_payload = payload
			received_channel = channel
		end
	)

	T(received_payload)["=="]("hello world")
	T(received_channel)["=="](0)
end)

T.Test("EventQueue:Process handles mixed event types", function()
	local queue = event_queue.CreateQueue()
	local peer = {id = 1}
	local events_received = {}

	queue:Push(event_queue.Event.New(event_queue.EVENT.CONNECT, peer))
	queue:Push(event_queue.Event.New(event_queue.EVENT.RECEIVE, peer, {
		payload = "data1",
		channel = 0,
	}))
	queue:Push(event_queue.Event.New(event_queue.EVENT.RECEIVE, peer, {
		payload = "data2",
		channel = 1,
	}))
	queue:Push(event_queue.Event.New(event_queue.EVENT.DISCONNECT, peer))

	queue:Process(
		function(p, data) events_received[#events_received + 1] = "connect" end,
		function(p, data) events_received[#events_received + 1] = "disconnect" end,
		function(p, payload, channel) events_received[#events_received + 1] = "receive:" .. payload end
	)

	T(#events_received)["=="](4)
	T(events_received[1])["=="]("connect")
	T(events_received[2])["=="]("receive:data1")
	T(events_received[3])["=="]("receive:data2")
	T(events_received[4])["=="]("disconnect")
end)

T.Test("EventQueue:Process is FIFO order", function()
	local queue = event_queue.CreateQueue()
	local order = {}

	for i = 1, 5 do
		queue:Push(event_queue.Event.New(event_queue.EVENT.RECEIVE, nil, {
			payload = "msg" .. i,
			channel = 0,
		}))
	end

	queue:Process(nil, nil, function(p, payload, channel)
		order[#order + 1] = payload
	end)

	T(#order)["=="](5)
	T(order[1])["=="]("msg1")
	T(order[5])["=="]("msg5")
end)

T.Test("EventQueue:Process with no callbacks does nothing", function()
	local queue = event_queue.CreateQueue()
	queue:Push(event_queue.Event.New(event_queue.EVENT.CONNECT, nil))

	-- Should not error
	queue:Process(nil, nil, nil)
	T(queue:IsEmpty())["=="](true)
end)

T.Test("Multiple queues are independent", function()
	local queue1 = event_queue.CreateQueue()
	local queue2 = event_queue.CreateQueue()

	queue1:Push(event_queue.Event.New(event_queue.EVENT.CONNECT, {id = 1}))
	queue2:Push(event_queue.Event.New(event_queue.EVENT.CONNECT, {id = 2}))

	T(queue1:GetSize())["=="](1)
	T(queue2:GetSize())["=="](1)

	local event1 = queue1:Pop()
	local event2 = queue2:Pop()

	T(event1.peer.id)["=="](1)
	T(event2.peer.id)["=="](2)
end)

return {}

-- Integration tests — End-to-end reliable UDP transport

local T = import("test/environment.lua")
local bit = require("bit")

-- Import all network modules
local packet_header = import("goluwa/network/packet_header.lua")
local sequence = import("goluwa/network/sequence.lua")
local ack = import("goluwa/network/ack.lua")
local reliable_send = import("goluwa/network/reliable_send.lua")
local channels = import("goluwa/network/channels.lua")
local event_queue = import("goluwa/network/event_queue.lua")
local handshake = import("goluwa/network/handshake.lua")

-- Helper: simulate wire transmission (loopback)
local function SendOverLoopback(sender, receiver, payload, flags, channel)
	-- Serialize on sender side
	local header = packet_header.WriteHeader({
		type = packet_header.PACKET_TYPE.DATA,
		flags = flags or 0,
		packet_id = sender.next_id or 0,
		channel = channel or 0,
		fragment_id = 1,
		total_fragments = 1,
	})
	sender.next_id = (sender.next_id or 0) + 1

	local framed = packet_header.Frame(payload)
	local full_packet = header .. framed

	-- Deserialize on receiver side
	local rx_header = packet_header.ReadHeader(full_packet)
	local rx_payload = packet_header.Unframe(full_packet)

	return rx_header, rx_payload
end

T.Test("Integration: Full handshake flow", function()
	-- Create client and server peer states
	local client = handshake.CreatePeerState()
	local server = handshake.CreatePeerState()
	server.peer_id = 100

	-- Step 1: Client sends connect request
	T(client.state)["=="](handshake.STATE.DISCONNECTED)
	local client_request = client:SendConnectRequest({ip = "127.0.0.1", port = 9000}, 50)
	T(client.state)["=="](handshake.STATE.CONNECTING)
	T(client_request.type)["=="](handshake.PACKET_TYPE.CONNECT_REQUEST)

	-- Step 2: Server receives and accepts
	local server_response = server:HandleConnectRequest({ip = "127.0.0.1", port = 9000}, client_request)
	T(server.state)["=="](handshake.STATE.CONNECTED)
	T(server_response.type)["=="](handshake.PACKET_TYPE.CONNECT_ACCEPT)

	-- Step 3: Client receives accept
	local confirm = client:HandleConnectAccept(server_response)
	T(client.state)["=="](handshake.STATE.CONNECTED)

	-- Both connected!
	T(client.state)["=="](handshake.STATE.CONNECTED)
	T(server.state)["=="](handshake.STATE.CONNECTED)
end)

T.Test("Integration: Reliable data transfer with sequencing", function()
	local sender_seq = sequence.Sender.New()
	local receiver_seq = sequence.Receiver.New()

	-- Send 5 reliable packets
	local received_packets = {}

	for i = 1, 5 do
		local seq = sender_seq:AllocateSequence()
		local payload = "message_" .. i

		-- Receiver processes
		local accepted = receiver_seq:Receive(seq)
		T(accepted)["=="](true)

		received_packets[#received_packets + 1] = {
			sequence = seq,
			payload = payload,
		}
	end

	-- Verify all packets received in order
	T(#received_packets)["=="](5)
	T(received_packets[1].payload)["=="]("message_1")
	T(received_packets[5].payload)["=="]("message_5")

	-- Try to send duplicate — should be rejected
	local dup_seq = sender_seq:AllocateSequence() -- Get a new seq (not a duplicate)
	receiver_seq:Receive(dup_seq) -- This is fine, it's a new seq

	-- Now try actual duplicate
	local test_receiver = sequence.Receiver.New()
	test_receiver:Receive(100)
	local dup_result = test_receiver:Receive(100)
	T(dup_result)["=="](false)
end)

T.Test("Integration: ACK bitmap round-trip", function()
	-- Receiver accumulates some packets
	local receiver = sequence.Receiver.New()
	receiver:Receive(100)
	receiver:Receive(101)
	receiver:Receive(102)

	-- Create ACK header
	local ack_header = ack.CreateAckHeader(receiver, 100)
	T(ack_header.ack_count)["=="](3)

	-- Serialize
	local bytes = ack.SerializeAckHeader(ack_header)
	T(#bytes)[">="](6)

	-- Deserialize
	local deserialized = ack.DeserializeAckHeader(bytes)
	T(deserialized.base_sequence)["=="](100)
	T(deserialized.ack_count)["=="](3)
end)

T.Test("Integration: Per-channel isolation", function()
	local peer = channels.CreatePeerChannels(10)

	-- Create two channels with different reliability
	local channel0 = peer:GetChannel(0, {reliability = reliable_send.RELIABILITY.RELIABLE})
	local channel1 = peer:GetChannel(1, {reliability = reliable_send.RELIABILITY.UNRELIABLE})

	-- Send on both channels
	local pkt0 = channel0:Send("reliable data")
	local pkt1 = channel1:Send("unreliable data")

	T(pkt0.reliability)["=="](reliable_send.RELIABILITY.RELIABLE)
	T(pkt1.reliability)["=="](reliable_send.RELIABILITY.UNRELIABLE)

	-- Each channel has its own independent sequence space
	-- Send a second packet on channel0 — should get seq=2
	local pkt0_b = channel0:Send("reliable data 2")
	T(pkt0_b.sequence_number)["=="](2)

	-- Channel1 still at seq=1 (independent)
	local pkt1_b = channel1:Send("unreliable data 2")
	T(pkt1_b.sequence_number)["=="](2)
end)

T.Test("Integration: Event queue dispatches connect/receive/disconnect", function()
	local queue = event_queue.CreateQueue()
	local peer = {id = 1, name = "TestPeer"}
	local events = {}

	-- Queue up mixed events
	queue:Push(event_queue.Event.New(event_queue.EVENT.CONNECT, peer))
	queue:Push(event_queue.Event.New(event_queue.EVENT.RECEIVE, peer, {
		payload = "hello",
		channel = 0,
	}))
	queue:Push(event_queue.Event.New(event_queue.EVENT.RECEIVE, peer, {
		payload = "world",
		channel = 1,
	}))
	queue:Push(event_queue.Event.New(event_queue.EVENT.DISCONNECT, peer))

	-- Process with callbacks
	queue:Process(
		function(p, data) events[#events + 1] = "connect:" .. p.id end,
		function(p, data) events[#events + 1] = "disconnect:" .. p.id end,
		function(p, payload, channel) events[#events + 1] = "receive:" .. payload end
	)

	T(#events)["=="](4)
	T(events[1])["=="]("connect:1")
	T(events[2])["=="]("receive:hello")
	T(events[3])["=="]("receive:world")
	T(events[4])["=="]("disconnect:1")
end)

T.Test("Integration: Packet header framing round-trip", function()
	local original = "Hello, World!"

	-- Frame it (use FrameString for strings)
	local framed = packet_header.FrameString(original)
	T(#framed)[">="](#original)

	-- Unframe it
	local header, payload_bytes = packet_header.Unframe(framed)
	T(header)["~="](nil)

	-- Convert bytes back to string
	local unframed = ""

	for _, b in ipairs(payload_bytes) do
		unframed = unframed .. string.char(b)
	end

	T(unframed)["=="](original)
end)

T.Test("Integration: Fragmentation and reassembly", function()
	local large_payload = string.rep("A", 5000) -- Larger than MaxPayload

	-- Convert to byte table for Fragment
	local payload_bytes = {}

	for i = 1, #large_payload do
		payload_bytes[i] = large_payload:byte(i)
	end

	-- Fragment
	local fragments = packet_header.Fragment(payload_bytes)
	T(#fragments)[">="](2)

	-- Reassemble
	local reassembled_bytes = packet_header.Reassemble(fragments)

	-- Convert back to string
	local reassembled = ""

	for _, b in ipairs(reassembled_bytes) do
		reassembled = reassembled .. string.char(b)
	end

	T(reassembled)["=="](large_payload)
end)

T.Test("Integration: Reliable send with retransmission tracking", function()
	local tracker = reliable_send.CreateTracker()

	-- Send 3 packets
	tracker:TrackPacket(1, "data1", reliable_send.RELIABILITY.RELIABLE)
	tracker:TrackPacket(2, "data2", reliable_send.RELIABILITY.RELIABLE)
	tracker:TrackPacket(3, "data3", reliable_send.RELIABILITY.RELIABLE)

	T(tracker.total_sent)["=="](3)

	-- Ack packets 1 and 2
	tracker:AckPacket(1)
	tracker:AckPacket(2)

	T(tracker.total_acked)["=="](2)
	T(tracker.unacked[3])["~="](nil)

	-- Force timeout on packet 3
	for _, p in pairs(tracker.unacked) do
		p.send_time = os.clock() * 1000 - 10000
	end

	local retransmit, failed = tracker:OnTimeout(os.clock() * 1000)
	T(#retransmit)["=="](1)
	T(retransmit[1].sequence_number)["=="](3)

	-- Final ack
	tracker:AckPacket(3)
	T(tracker.total_acked)["=="](3)
	T(#tracker.unacked)["=="](0)
end)

T.Test("Integration: End-to-end client-server simulation", function()
	-- Setup
	local client_channels = channels.CreatePeerChannels(10)
	local server_channels = channels.CreatePeerChannels(10)
	local client_events = event_queue.CreateQueue()
	local server_events = event_queue.CreateQueue()

	-- Handshake
	local client = handshake.CreatePeerState()
	local server = handshake.CreatePeerState()
	server.peer_id = 999

	local client_request = client:SendConnectRequest({ip = "127.0.0.1", port = 9000}, 123)
	T(client.state)["=="](handshake.STATE.CONNECTING)

	local server_response = server:HandleConnectRequest({ip = "127.0.0.1", port = 9000}, client_request)
	T(server.state)["=="](handshake.STATE.CONNECTED)

	local confirm = client:HandleConnectAccept(server_response)
	T(client.state)["=="](handshake.STATE.CONNECTED)

	-- Queue connect events
	client_events:Push(event_queue.Event.New(event_queue.EVENT.CONNECT, {id = "client"}))
	server_events:Push(event_queue.Event.New(event_queue.EVENT.CONNECT, {id = "server"}))

	-- Client sends reliable message to server
	local client_channel0 = client_channels:GetChannel(0)
	local packet = client_channel0:Send("Hello Server!")

	-- Server receives (simulated — in real code this comes over UDP with the sequence number)
	-- The key insight: receiver on server side needs to accept this sequence number
	local server_channel0 = server_channels:GetChannel(0)

	-- First packet on this channel establishes the window
	local received = server_channel0:Receive(packet.sequence_number, "Hello Server!")
	T(received)["~="](nil)
	T(received.payload)["=="]("Hello Server!")

	-- Queue receive event on server
	server_events:Push(event_queue.Event.New(event_queue.EVENT.RECEIVE, {id = "server"}, {
		payload = received.payload,
		channel = 0,
	}))

	-- Application drains events
	local client_connected = false
	local server_received = nil

	client_events:Process(
		function(p, d) client_connected = true end,
		nil,
		nil
	)

	server_events:Process(
		nil,
		nil,
		function(p, payload, ch) server_received = payload end
	)

	T(client_connected)["=="](true)
	T(server_received)["=="]("Hello Server!")

	-- Cleanup — client initiates disconnect
	local disconnect_pkt = client:SendDisconnect("bye")
	T(client.state)["=="](handshake.STATE.DISCONNECTING)

	-- Server receives disconnect
	server:HandleDisconnect(disconnect_pkt)
	T(server.state)["=="](handshake.STATE.DISCONNECTED)

	-- Client receives disconnect confirmation
	client:HandleDisconnect(disconnect_pkt)
	T(client.state)["=="](handshake.STATE.DISCONNECTED)
end)

T.Test("Integration: Out-of-order packets within window", function()
	local receiver = sequence.Receiver.New()

	-- Receive out of order: 100 establishes window, then 102, 101 (all ahead of window start)
	-- Receiver:Receive only takes seq number
	local results = {}
	results[1] = receiver:Receive(100) -- Establishes window at [100, 163]
	results[2] = receiver:Receive(102) -- Within window
	results[3] = receiver:Receive(101) -- Within window

	-- All should be accepted (within window)
	T(results[1])["=="](true)
	T(results[2])["=="](true)
	T(results[3])["=="](true)

	T(receiver.received_count)["=="](3)
end)

T.Test("Integration: Window boundary rejection", function()
	local receiver = sequence.Receiver.New()

	-- Establish window with first packet
	receiver:Receive(100)

	-- Try packet far behind window
	local result = receiver:Receive(1, "too_old")
	T(result)["=="](false)
end)

return {}

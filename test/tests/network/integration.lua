local T = import("test/environment.lua")
local bit = require("bit")
local packet_header = import("goluwa/network/packet_header.lua")
local sequence = import("goluwa/network/sequence.lua")
local ack = import("goluwa/network/ack.lua")
local reliable_send = import("goluwa/network/reliable_send.lua")
local channels = import("goluwa/network/channels.lua")
local event_queue = import("goluwa/network/event_queue.lua")
local handshake = import("goluwa/network/handshake.lua")

local function SendOverLoopback(sender, receiver, payload, flags, channel)
	local header = packet_header.WriteHeader{
		type = packet_header.PACKET_TYPE.DATA,
		flags = flags or 0,
		packet_id = sender.next_id or 0,
		channel = channel or 0,
		fragment_id = 1,
		total_fragments = 1,
	}
	sender.next_id = (sender.next_id or 0) + 1
	local framed = packet_header.Frame(payload)
	local full_packet = header .. framed
	local rx_header = packet_header.ReadHeader(full_packet)
	local rx_payload = packet_header.Unframe(full_packet)
	return rx_header, rx_payload
end

T.Test("Integration: Full handshake flow", function()
	local client = handshake.CreatePeerState()
	local server = handshake.CreatePeerState()
	server.peer_id = 100
	T(client.state)["=="](handshake.STATE.DISCONNECTED)
	local client_request = client:SendConnectRequest({ip = "127.0.0.1", port = 9000}, 50)
	T(client.state)["=="](handshake.STATE.CONNECTING)
	T(client_request.type)["=="](handshake.PACKET_TYPE.CONNECT_REQUEST)
	local server_response = server:HandleConnectRequest({ip = "127.0.0.1", port = 9000}, client_request)
	T(server.state)["=="](handshake.STATE.CONNECTED)
	T(server_response.type)["=="](handshake.PACKET_TYPE.CONNECT_ACCEPT)
	local confirm = client:HandleConnectAccept(server_response)
	T(client.state)["=="](handshake.STATE.CONNECTED)
	T(client.state)["=="](handshake.STATE.CONNECTED)
	T(server.state)["=="](handshake.STATE.CONNECTED)
end)

T.Test("Integration: Reliable data transfer with sequencing", function()
	local sender_seq = sequence.Sender.New()
	local receiver_seq = sequence.Receiver.New()
	local received_packets = {}

	for i = 1, 5 do
		local seq = sender_seq:AllocateSequence()
		local payload = "message_" .. i
		local accepted = receiver_seq:Receive(seq)
		T(accepted)["=="](true)
		received_packets[#received_packets + 1] = {
			sequence = seq,
			payload = payload,
		}
	end

	T(#received_packets)["=="](5)
	T(received_packets[1].payload)["=="]("message_1")
	T(received_packets[5].payload)["=="]("message_5")
	local dup_seq = sender_seq:AllocateSequence()
	receiver_seq:Receive(dup_seq)
	local test_receiver = sequence.Receiver.New()
	test_receiver:Receive(100)
	local dup_result = test_receiver:Receive(100)
	T(dup_result)["=="](false)
end)

T.Test("Integration: ACK bitmap round-trip", function()
	local receiver = sequence.Receiver.New()
	receiver:Receive(100)
	receiver:Receive(101)
	receiver:Receive(102)
	local ack_header = ack.CreateAckHeader(receiver, 100)
	T(ack_header.ack_count)["=="](3)
	local bytes = ack.SerializeAckHeader(ack_header)
	T(#bytes)[">="](6)
	local deserialized = ack.DeserializeAckHeader(bytes)
	T(deserialized.base_sequence)["=="](100)
	T(deserialized.ack_count)["=="](3)
end)

T.Test("Integration: Per-channel isolation", function()
	local peer = channels.CreatePeerChannels(10)
	local channel0 = peer:GetChannel(0, {reliability = reliable_send.RELIABILITY.RELIABLE})
	local channel1 = peer:GetChannel(1, {reliability = reliable_send.RELIABILITY.UNRELIABLE})
	local pkt0 = channel0:Send("reliable data")
	local pkt1 = channel1:Send("unreliable data")
	T(pkt0.reliability)["=="](reliable_send.RELIABILITY.RELIABLE)
	T(pkt1.reliability)["=="](reliable_send.RELIABILITY.UNRELIABLE)
	local pkt0_b = channel0:Send("reliable data 2")
	T(pkt0_b.sequence_number)["=="](2)
	local pkt1_b = channel1:Send("unreliable data 2")
	T(pkt1_b.sequence_number)["=="](2)
end)

T.Test("Integration: Event queue dispatches connect/receive/disconnect", function()
	local queue = event_queue.CreateQueue()
	local peer = {id = 1, name = "TestPeer"}
	local events = {}
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

	queue:Process(function(p, data)
		events[#events + 1] = "connect:" .. p.id
	end, function(p, data)
		events[#events + 1] = "disconnect:" .. p.id
	end, function(p, payload, channel)
		events[#events + 1] = "receive:" .. payload
	end)

	T(#events)["=="](4)
	T(events[1])["=="]("connect:1")
	T(events[2])["=="]("receive:hello")
	T(events[3])["=="]("receive:world")
	T(events[4])["=="]("disconnect:1")
end)

T.Test("Integration: Packet header framing round-trip", function()
	local original = "Hello, World!"
	local framed = packet_header.FrameString(original)
	T(#framed)[">="](#original)
	local header, payload_bytes = packet_header.Unframe(framed)
	T(header)["~="](nil)
	local unframed = ""

	for _, b in ipairs(payload_bytes) do
		unframed = unframed .. string.char(b)
	end

	T(unframed)["=="](original)
end)

T.Test("Integration: Fragmentation and reassembly", function()
	local large_payload = string.rep("A", 5000)
	local payload_bytes = {}

	for i = 1, #large_payload do
		payload_bytes[i] = large_payload:byte(i)
	end

	local fragments = packet_header.Fragment(payload_bytes)
	T(#fragments)[">="](2)
	local reassembled_bytes = packet_header.Reassemble(fragments)
	local reassembled = ""

	for _, b in ipairs(reassembled_bytes) do
		reassembled = reassembled .. string.char(b)
	end

	T(reassembled)["=="](large_payload)
end)

T.Test("Integration: Reliable send with retransmission tracking", function()
	local tracker = reliable_send.CreateTracker()
	tracker:TrackPacket(1, "data1", reliable_send.RELIABILITY.RELIABLE)
	tracker:TrackPacket(2, "data2", reliable_send.RELIABILITY.RELIABLE)
	tracker:TrackPacket(3, "data3", reliable_send.RELIABILITY.RELIABLE)
	T(tracker.total_sent)["=="](3)
	tracker:AckPacket(1)
	tracker:AckPacket(2)
	T(tracker.total_acked)["=="](2)
	T(tracker.unacked[3])["~="](nil)

	for _, p in pairs(tracker.unacked) do
		p.send_time = os.clock() * 1000 - 10000
	end

	local retransmit, failed = tracker:OnTimeout(os.clock() * 1000)
	T(#retransmit)["=="](1)
	T(retransmit[1].sequence_number)["=="](3)
	tracker:AckPacket(3)
	T(tracker.total_acked)["=="](3)
	T(#tracker.unacked)["=="](0)
end)

T.Test("Integration: End-to-end client-server simulation", function()
	local client_channels = channels.CreatePeerChannels(10)
	local server_channels = channels.CreatePeerChannels(10)
	local client_events = event_queue.CreateQueue()
	local server_events = event_queue.CreateQueue()
	local client = handshake.CreatePeerState()
	local server = handshake.CreatePeerState()
	server.peer_id = 999
	local client_request = client:SendConnectRequest({ip = "127.0.0.1", port = 9000}, 123)
	T(client.state)["=="](handshake.STATE.CONNECTING)
	local server_response = server:HandleConnectRequest({ip = "127.0.0.1", port = 9000}, client_request)
	T(server.state)["=="](handshake.STATE.CONNECTED)
	local confirm = client:HandleConnectAccept(server_response)
	T(client.state)["=="](handshake.STATE.CONNECTED)
	client_events:Push(event_queue.Event.New(event_queue.EVENT.CONNECT, {id = "client"}))
	server_events:Push(event_queue.Event.New(event_queue.EVENT.CONNECT, {id = "server"}))
	local client_channel0 = client_channels:GetChannel(0)
	local packet = client_channel0:Send("Hello Server!")
	local server_channel0 = server_channels:GetChannel(0)
	local received = server_channel0:Receive(packet.sequence_number, "Hello Server!")
	T(received)["~="](nil)
	T(received.payload)["=="]("Hello Server!")
	server_events:Push(
		event_queue.Event.New(event_queue.EVENT.RECEIVE, {id = "server"}, {
			payload = received.payload,
			channel = 0,
		})
	)
	local client_connected = false
	local server_received = nil

	client_events:Process(function(p, d)
		client_connected = true
	end, nil, nil)

	server_events:Process(nil, nil, function(p, payload, ch)
		server_received = payload
	end)

	T(client_connected)["=="](true)
	T(server_received)["=="]("Hello Server!")
	local disconnect_pkt = client:SendDisconnect("bye")
	T(client.state)["=="](handshake.STATE.DISCONNECTING)
	server:HandleDisconnect(disconnect_pkt)
	T(server.state)["=="](handshake.STATE.DISCONNECTED)
	client:HandleDisconnect(disconnect_pkt)
	T(client.state)["=="](handshake.STATE.DISCONNECTED)
end)

T.Test("Integration: Out-of-order packets within window", function()
	local receiver = sequence.Receiver.New()
	local results = {}
	results[1] = receiver:Receive(100)
	results[2] = receiver:Receive(102)
	results[3] = receiver:Receive(101)
	T(results[1])["=="](true)
	T(results[2])["=="](true)
	T(results[3])["=="](true)
	T(receiver.received_count)["=="](3)
end)

T.Test("Integration: Window boundary rejection", function()
	local receiver = sequence.Receiver.New()
	receiver:Receive(100)
	local result = receiver:Receive(1, "too_old")
	T(result)["=="](false)
end)

return {}

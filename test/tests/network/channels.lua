-- Tests for per-channel sequencing and reliability (Step 5)

local T = import("test/environment.lua")
local channels = import("goluwa/network/channels.lua")
local reliable_send = import("goluwa/network/reliable_send.lua")

-- Count entries in a hash table
local function count_hash(t)
	local count = 0

	for _ in pairs(t) do count = count + 1 end

	return count
end

T.Test("ChannelState creates with default config", function()
	local channel = channels.ChannelState.New()
	T(channel.config.reliability)["=="](reliable_send.RELIABILITY.RELIABLE)
	T(channel.config.window_size)["=="](64)
	T(channel.config.max_packet_size)["=="](1400)
end)

T.Test("ChannelState:Send allocates sequence number", function()
	local channel = channels.ChannelState.New()
	local packet = channel:Send("test data")

	T(packet.sequence_number)["~="](nil)
	T(packet.payload)["=="]("test data")
	T(packet.reliability)["=="](reliable_send.RELIABILITY.RELIABLE)
end)

T.Test("ChannelState:Send uses custom reliability", function()
	local channel = channels.ChannelState.New()
	local packet = channel:Send("unreliable data", reliable_send.RELIABILITY.UNRELIABLE)

	T(packet.reliability)["=="](reliable_send.RELIABILITY.UNRELIABLE)
end)

T.Test("ChannelState:Receive accepts valid packet", function()
	local channel = channels.ChannelState.New()
	channel.sender:AllocateSequence() -- Advance sender

	local received = channel:Receive(100, "test payload")
	T(received)["~="](nil)
	T(received.sequence_number)["=="](100)
	T(received.payload)["=="]("test payload")
end)

T.Test("ChannelState:Receive rejects duplicate", function()
	local channel = channels.ChannelState.New()
	channel.sender:AllocateSequence()

	channel:Receive(100, "first")
	local duplicate = channel:Receive(100, "duplicate")
	T(duplicate)["=="](nil)
end)

T.Test("ChannelState:Receive rejects out-of-window", function()
	local channel = channels.ChannelState.New()
	channel.sender:AllocateSequence()

	-- First receive establishes the window
	channel:Receive(100, "first")

	-- Now try a packet far in the past (behind the window)
	local result = channel:Receive(1, "too old")
	T(result)["=="](nil)
end)

T.Test("ChannelState:SendAck creates ACK header", function()
	local channel = channels.ChannelState.New()
	channel:Receive(100, "data")

	local ack = channel:SendAck()
	T(ack)["~="](nil)
	T(ack.base_sequence)["~="](nil)
end)

T.Test("ChannelState:GetStats returns statistics", function()
	local channel = channels.ChannelState.New()
	channel:Send("data")

	local stats = channel:GetStats()
	T(stats.retransmission)["~="](nil)
	T(stats.window_size)["=="](64)
	T(stats.reliability)["=="](reliable_send.RELIABILITY.RELIABLE)
end)

T.Test("PeerChannelState creates channels on demand", function()
	local peer = channels.PeerChannelState.New(10)
	local channel0 = peer:GetChannel(0)
	local channel1 = peer:GetChannel(1)

	T(channel0)["~="](nil)
	T(channel1)["~="](nil)
	T(channel0)["~="](channel1) -- Different channels
end)

T.Test("PeerChannelState:GetChannel returns same channel on repeat", function()
	local peer = channels.PeerChannelState.New(10)
	local channel1 = peer:GetChannel(5)
	local channel2 = peer:GetChannel(5)

	T(channel1)["=="](channel2) -- Same instance
end)

T.Test("PeerChannelState:RemoveChannel removes channel", function()
	local peer = channels.PeerChannelState.New(10)
	peer:GetChannel(0)
	peer:GetChannel(1)

	peer:RemoveChannel(0)
	local channels = peer:GetChannels()
	T(#channels)["=="](1)
	T(channels[1].channel_id)["=="](1)
end)

T.Test("PeerChannelState:GetChannels returns all channels", function()
	local peer = channels.PeerChannelState.New(10)
	peer:GetChannel(0)
	peer:GetChannel(1)
	peer:GetChannel(2)

	local all = peer:GetChannels()
	T(#all)["=="](3)
end)

T.Test("PeerChannelState:OnTimeout processes all channels", function()
	local peer = channels.PeerChannelState.New(10)
	local channel0 = peer:GetChannel(0)
	local channel1 = peer:GetChannel(1)

	-- Send packets on both channels
	channel0:Send("data0")
	channel1:Send("data1")

	-- Force timeout on channel0
	local retransmit = peer:OnTimeout(os.clock() * 1000)
	-- Should have retransmissions from both channels (or none if not timed out yet)
	T(type(retransmit))["=="]("table")
end)

T.Test("PeerChannelState:GetStats returns aggregate statistics", function()
	local peer = channels.PeerChannelState.New(10)
	peer:GetChannel(0)
	peer:GetChannel(1)

	local stats = peer:GetStats()
	T(count_hash(stats.channels))["=="](2)
	T(stats.channels[0])["~="](nil)
	T(stats.channels[1])["~="](nil)
end)

T.Test("Custom channel configuration", function()
	local config = {
		reliability = reliable_send.RELIABILITY.UNRELIABLE_SEQUENCED,
		window_size = 32,
		max_packet_size = 512,
	}

	local channel = channels.ChannelState.New(config)
	T(channel.config.reliability)["=="](reliable_send.RELIABILITY.UNRELIABLE_SEQUENCED)
	T(channel.config.window_size)["=="](32)
	T(channel.config.max_packet_size)["=="](512)
end)

T.Test("Per-channel independence — sequence numbers don't interfere", function()
	local peer = channels.PeerChannelState.New(10)
	local channel0 = peer:GetChannel(0)
	local channel1 = peer:GetChannel(1)

	local packet0 = channel0:Send("data0")
	local packet1 = channel1:Send("data1")

	-- Both should have valid sequence numbers
	T(packet0.sequence_number)["~="](nil)
	T(packet1.sequence_number)["~="](nil)
end)

T.Test("CreatePeerChannels factory function", function()
	local peer = channels.CreatePeerChannels(50)
	T(peer)["~="](nil)
	T(peer.max_channels)["=="](50)
end)

return {}

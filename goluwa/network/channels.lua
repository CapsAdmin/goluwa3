-- Channels — Per-channel sequencing, ACK, and reliability policy
-- Part of Step 5: reliable UDP transport layer

local bit = require("bit")
local sequence = import("goluwa/network/sequence.lua")
local reliable_send = import("goluwa/network/reliable_send.lua")
local channels = {}

-- Default channel configuration
channels.DEFAULT_CONFIG = {
	reliability = reliable_send.RELIABILITY.RELIABLE, -- Default to reliable
	window_size = sequence.WINDOW_SIZE,                -- 64 packets
	max_packet_size = 1400,                            -- MTU-like limit
}

-- Channel state — independent sequence/ACK per channel
local ChannelState = {}
ChannelState.__index = ChannelState

function ChannelState.New(config)
	local self = setmetatable({}, ChannelState)
	self.config = config or channels.DEFAULT_CONFIG
	self.sender = sequence.Sender.New()
	self.receiver = sequence.Receiver.New()
	self.retransmission = reliable_send.CreateTracker()
	self.sequence_number = 0
	return self
end

-- Send a packet on this channel
function ChannelState:Send(payload, reliability)
	reliability = reliability or self.config.reliability

	-- Allocate sequence number
	local seq = self.sender:AllocateSequence()
	self.sequence_number = seq

	-- Track for retransmission if reliable
	if reliability == reliable_send.RELIABILITY.RELIABLE then
		self.retransmission:TrackPacket(seq, payload, reliability)
	end

	return {
		sequence_number = seq,
		payload = payload,
		reliability = reliability,
		channel_id = self.channel_id,
	}
end

-- Receive a packet on this channel
function ChannelState:Receive(sequence_number, payload)
	-- Mark as received and check for duplicates
	local accepted = self.receiver:Receive(sequence_number)

	if not accepted then
		return nil -- Duplicate or out-of-window
	end

	-- Acknowledge the packet
	if self.receiver.received_count > 0 then
		self:SendAck()
	end

	return {
		sequence_number = sequence_number,
		payload = payload,
		channel_id = self.channel_id,
	}
end

-- Process incoming ACK
function ChannelState:ProcessAck(ack_header)
	if ack_header and ack_header.base_sequence then
		self.retransmission:AckPacket(ack_header.base_sequence)
	end
end

-- Get retransmission queue for this channel
function ChannelState:GetRetransmitQueue(current_time)
	return self.retransmission:GetRetransmitQueue(current_time)
end

-- Process retransmission timeouts
function ChannelState:OnTimeout(current_time)
	return self.retransmission:OnTimeout(current_time)
end

-- Send ACK for received packets
function ChannelState:SendAck()
	-- Create ACK header from receiver state
	local ack_header = require("goluwa/network/ack").CreateAckHeader(self.receiver, self.receiver.window_start)
	return ack_header
end

-- Get channel statistics
function ChannelState:GetStats()
	return {
		retransmission = self.retransmission:GetStats(),
		window_size = self.config.window_size,
		reliability = self.config.reliability,
	}
end

-- Peer state — manages multiple channels
local PeerChannelState = {}
PeerChannelState.__index = PeerChannelState

function PeerChannelState.New(max_channels)
	local self = setmetatable({}, PeerChannelState)
	self.max_channels = max_channels or 256
	self.channels = {} -- channel_id -> ChannelState
	return self
end

-- Get or create a channel
function PeerChannelState:GetChannel(channel_id, config)
	if not self.channels[channel_id] then
		if #self.channels >= self.max_channels then
			error("Maximum channels reached")
		end

		self.channels[channel_id] = ChannelState.New(config)
		self.channels[channel_id].channel_id = channel_id
	end

	return self.channels[channel_id]
end

-- Remove a channel
function PeerChannelState:RemoveChannel(channel_id)
	self.channels[channel_id] = nil
end

-- Get all channels
function PeerChannelState:GetChannels()
	local result = {}

	for _, channel in pairs(self.channels) do
		result[#result + 1] = channel
	end

	return result
end

-- Process retransmission for all channels
function PeerChannelState:OnTimeout(current_time)
	local retransmit = {}

	for _, channel in pairs(self.channels) do
		local channel_retransmit, _ = channel:OnTimeout(current_time)

		for _, packet in ipairs(channel_retransmit) do
			retransmit[#retransmit + 1] = {
				channel = channel,
				packet = packet,
			}
		end
	end

	return retransmit
end

-- Get statistics for all channels
function PeerChannelState:GetStats()
	local stats = {
		channel_count = #self.channels,
		channels = {},
	}

	for id, channel in pairs(self.channels) do
		stats.channels[id] = channel:GetStats()
	end

	return stats
end

-- Export classes
channels.ChannelState = ChannelState
channels.PeerChannelState = PeerChannelState
channels.CreatePeerChannels = function(max_channels) return PeerChannelState.New(max_channels) end

return channels

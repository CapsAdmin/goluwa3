local bit = require("bit")
local get_time = import("goluwa/bindings/time.lua")
local reliable_send = {}

function reliable_send.Now()
	return get_time() * 1000
end

reliable_send.RELIABILITY = {
	UNRELIABLE = 0,
	UNRELIABLE_SEQUENCED = 1,
	RELIABLE = 2,
}
reliable_send.DEFAULT_INITIAL_TIMEOUT = 200
reliable_send.DEFAULT_MAX_TIMEOUT = 2000
reliable_send.DEFAULT_MULTIPLIER = 2
reliable_send.DEFAULT_JITTER = 0.1
reliable_send.DEFAULT_MAX_RETRIES = 8
local UnackedPacket = {}
UnackedPacket.__index = UnackedPacket

function UnackedPacket.New(sequence_number, payload, reliability, send_time)
	local self = setmetatable({}, UnackedPacket)
	self.sequence_number = sequence_number
	self.payload = payload
	self.reliability = reliability
	self.send_time = send_time
	self.retry_count = 0
	self.timeout = reliable_send.DEFAULT_INITIAL_TIMEOUT
	self.acked = false
	return self
end

function UnackedPacket:NeedsRetransmission(current_time)
	if self.acked then return false end

	return (current_time - self.send_time) >= self.timeout
end

function UnackedPacket:Ack()
	self.acked = true
end

function UnackedPacket:OnTimeout()
	self.retry_count = self.retry_count + 1
	local backoff = math.pow(reliable_send.DEFAULT_MULTIPLIER, self.retry_count)
	local new_timeout = reliable_send.DEFAULT_INITIAL_TIMEOUT * backoff
	new_timeout = math.min(new_timeout, reliable_send.DEFAULT_MAX_TIMEOUT)
	local jitter_range = new_timeout * reliable_send.DEFAULT_JITTER
	new_timeout = new_timeout + (math.random() * 2 * jitter_range - jitter_range)
	self.timeout = new_timeout
	self.send_time = reliable_send.Now()
	return self.retry_count < reliable_send.DEFAULT_MAX_RETRIES
end

function UnackedPacket:HasExceededMaxRetries()
	return self.retry_count >= reliable_send.DEFAULT_MAX_RETRIES
end

local RetransmissionTracker = {}
RetransmissionTracker.__index = RetransmissionTracker

function RetransmissionTracker.New()
	local self = setmetatable({}, RetransmissionTracker)
	self.unacked = {}
	self.unacked_count = 0
	self.total_sent = 0
	self.total_acked = 0
	self.total_retransmitted = 0
	self.total_failed = 0
	return self
end

function RetransmissionTracker:TrackPacket(sequence_number, payload, reliability)
	local send_time = reliable_send.Now()
	local packet = UnackedPacket.New(sequence_number, payload, reliability, send_time)

	if not self.unacked[sequence_number] then
		self.unacked_count = self.unacked_count + 1
	end

	self.unacked[sequence_number] = packet
	self.total_sent = self.total_sent + 1
	return packet
end

function RetransmissionTracker:AckPacket(sequence_number)
	local packet = self.unacked[sequence_number]

	if packet then
		packet:Ack()
		self.unacked[sequence_number] = nil
		self.unacked_count = self.unacked_count - 1
		self.total_acked = self.total_acked + 1
		return true
	end

	return false
end

function RetransmissionTracker:GetRetransmitQueue(current_time)
	local retransmit = {}

	for seq, packet in pairs(self.unacked) do
		if packet:NeedsRetransmission(current_time) then
			retransmit[#retransmit + 1] = packet
		end
	end

	return retransmit
end

function RetransmissionTracker:OnTimeout(current_time)
	local retransmit = self:GetRetransmitQueue(current_time)
	local failed = {}

	for _, packet in ipairs(retransmit) do
		self.total_retransmitted = self.total_retransmitted + 1
		local should_continue = packet:OnTimeout()

		if not should_continue then failed[#failed + 1] = packet end
	end

	for _, packet in ipairs(failed) do
		self.unacked[packet.sequence_number] = nil
		self.unacked_count = self.unacked_count - 1
		self.total_failed = self.total_failed + 1
	end

	return retransmit, failed
end

function RetransmissionTracker:Cleanup(max_age_ms)
	local current_time = reliable_send.Now()
	local cleaned = 0

	for seq, packet in pairs(self.unacked) do
		if packet.acked and (current_time - packet.send_time) > max_age_ms then
			self.unacked[seq] = nil
			self.unacked_count = self.unacked_count - 1
			cleaned = cleaned + 1
		end
	end

	return cleaned
end

function RetransmissionTracker:GetStats()
	return {
		unacked = self.unacked_count,
		total_sent = self.total_sent,
		total_acked = self.total_acked,
		total_retransmitted = self.total_retransmitted,
		total_failed = self.total_failed,
	}
end

reliable_send.UnackedPacket = UnackedPacket
reliable_send.RetransmissionTracker = RetransmissionTracker

function reliable_send.CreateTracker()
	return RetransmissionTracker.New()
end

return reliable_send

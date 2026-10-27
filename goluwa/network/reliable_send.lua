local get_time = import("goluwa/bindings/time.lua")
local reliable_send = {}

function reliable_send.Now()
	return get_time() * 1000
end

reliable_send.INITIAL_RTO = 1000
reliable_send.MIN_RTO = 100
reliable_send.RTO_GRANULARITY = 50
reliable_send.MAX_RTO = 2000
reliable_send.LOSS_THRESHOLD = 3
reliable_send.DATAGRAM_SIZE = 1232
reliable_send.MIN_WINDOW = 64 * reliable_send.DATAGRAM_SIZE
reliable_send.MAX_WINDOW = 4 * 1024 * 1024
local Sender = {}
Sender.__index = Sender

function reliable_send.New()
	return setmetatable(
		{
			srtt = 0,
			rttvar = 0,
			rto = reliable_send.INITIAL_RTO,
			cwnd = reliable_send.MIN_WINDOW,
			ssthresh = math.huge,
			in_flight = 0,
			cwnd_limited = false,
			send_index = 0,
			largest_acked = -1,
			recovery_index = -1,
			total_sent = 0,
			total_acked = 0,
			total_lost = 0,
		},
		Sender
	)
end

function Sender:AddRttSample(rtt)
	if self.srtt == 0 then
		self.srtt = rtt
		self.rttvar = rtt / 2
	else
		self.rttvar = self.rttvar * 0.75 + math.abs(self.srtt - rtt) * 0.25
		self.srtt = self.srtt * 0.875 + rtt * 0.125
	end

	self.rto = math.clamp(
		self.srtt + math.max(reliable_send.RTO_GRANULARITY, 4 * self.rttvar),
		reliable_send.MIN_RTO,
		reliable_send.MAX_RTO
	)
end

function Sender:CanSend(size)
	return self.in_flight == 0 or self.in_flight + size <= self.cwnd
end

function Sender:OnSent(entry, now)
	entry.index = self.send_index
	entry.sent_at = now
	entry.first_sent_at = now
	entry.transmissions = 1
	self.send_index = self.send_index + 1
	self.in_flight = self.in_flight + entry.size
	self.total_sent = self.total_sent + 1
end

function Sender:OnAcked(entry)
	self.in_flight = self.in_flight - entry.size
	self.total_acked = self.total_acked + 1

	if entry.transmissions == 1 and entry.index > self.largest_acked then
		self.largest_acked = entry.index
	end

	if self.cwnd_limited and entry.index > self.recovery_index then
		if self.cwnd < self.ssthresh then
			self.cwnd = self.cwnd + entry.size
		else
			self.cwnd = self.cwnd + reliable_send.DATAGRAM_SIZE * entry.size / self.cwnd
		end

		if self.cwnd > reliable_send.MAX_WINDOW then
			self.cwnd = reliable_send.MAX_WINDOW
		end
	end
end

function Sender:CheckLost(entry, now)
	local age = now - entry.sent_at
	local timed_out = age >= self.rto

	if
		not timed_out and
		(
			entry.index + reliable_send.LOSS_THRESHOLD > self.largest_acked or
			age < self.srtt * 1.125
		)
	then
		return false
	end

	if entry.index > self.recovery_index then
		self.recovery_index = self.send_index - 1

		if self.srtt > 0 then
			self.ssthresh = math.max(self.cwnd / 2, reliable_send.MIN_WINDOW)
			self.cwnd = self.ssthresh
		end

		if timed_out then self.rto = math.min(self.rto * 2, reliable_send.MAX_RTO) end
	end

	entry.index = self.send_index
	entry.sent_at = now
	entry.transmissions = entry.transmissions + 1
	self.send_index = self.send_index + 1
	self.total_lost = self.total_lost + 1
	return true
end

return reliable_send

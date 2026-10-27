local T = import("test/environment.lua")
local reliable_send = import("goluwa/network/reliable_send.lua")

local function entry(size)
	return {size = size or 1000}
end

T.Test("Sender rto follows the measured round trip", function()
	local sender = reliable_send.New()
	T(sender.rto)["=="](reliable_send.INITIAL_RTO)
	sender:AddRttSample(300)
	T(sender.srtt)["=="](300)
	T(sender.rto)["=="](900)

	for _ = 1, 50 do
		sender:AddRttSample(300)
	end

	T(sender.rto)["=="](300 + reliable_send.RTO_GRANULARITY)
	sender:AddRttSample(1)

	for _ = 1, 50 do
		sender:AddRttSample(1)
	end

	T(sender.rto)["=="](reliable_send.MIN_RTO)
end)

T.Test("Sender ignores acks of retransmitted records for loss detection", function()
	local sender = reliable_send.New()
	local e = entry()
	sender:OnSent(e, 0)
	T(sender:CheckLost(e, reliable_send.INITIAL_RTO))["=="](true)
	sender:OnAcked(e)
	T(sender.largest_acked)["=="](-1)
	T(sender.in_flight)["=="](0)
end)

T.Test("Sender window allows one record over the window when idle", function()
	local sender = reliable_send.New()
	T(sender:CanSend(sender.cwnd * 2))["=="](true)
	local e = entry(sender.cwnd - 10)
	sender:OnSent(e, 0)
	T(sender:CanSend(5))["=="](true)
	T(sender:CanSend(20))["=="](false)
end)

T.Test("Sender window grows in slow start only while limited", function()
	local sender = reliable_send.New()
	local start = sender.cwnd
	local e = entry(1000)
	sender:OnSent(e, 0)
	sender:OnAcked(e)
	T(sender.cwnd)["=="](start)
	sender.cwnd_limited = true
	local e2 = entry(1000)
	sender:OnSent(e2, 10)
	sender:OnAcked(e2)
	T(sender.cwnd)["=="](start + 1000)
end)

T.Test("Sender declares a record lost once later records are acked", function()
	local sender = reliable_send.New()
	local lost = entry()
	sender:OnSent(lost, 0)
	local later = {}

	for i = 1, reliable_send.LOSS_THRESHOLD do
		later[i] = entry()
		sender:OnSent(later[i], 0)
	end

	for i = 1, reliable_send.LOSS_THRESHOLD - 1 do
		sender:OnAcked(later[i])
	end

	T(sender:CheckLost(lost, 10))["=="](false)
	sender:OnAcked(later[reliable_send.LOSS_THRESHOLD])
	T(sender:CheckLost(lost, 10))["=="](true)
	T(lost.transmissions)["=="](2)
	T(sender:CheckLost(lost, 11))["=="](false)
end)

T.Test("Sender halves the window once per loss episode and keeps the floor", function()
	local sender = reliable_send.New()
	sender:AddRttSample(100)
	sender.cwnd = reliable_send.MIN_WINDOW * 8
	local entries = {}

	for i = 1, 10 do
		entries[i] = entry()
		sender:OnSent(entries[i], 0)
	end

	for i = 1, 10 do
		sender:CheckLost(entries[i], 10000)
	end

	T(sender.cwnd)["=="](reliable_send.MIN_WINDOW * 4)

	for _ = 1, 10 do
		local e = entry()
		sender:OnSent(e, 20000)
		sender:CheckLost(e, 40000)
	end

	T(sender.cwnd)["=="](reliable_send.MIN_WINDOW)
end)

T.Test("Sender keeps the window when it times out before the first round trip sample", function()
	local sender = reliable_send.New()
	sender.cwnd = reliable_send.MIN_WINDOW * 4
	local e = entry()
	sender:OnSent(e, 0)
	T(sender:CheckLost(e, reliable_send.INITIAL_RTO))["=="](true)
	T(sender.cwnd)["=="](reliable_send.MIN_WINDOW * 4)
	T(sender.rto)["=="](math.min(reliable_send.INITIAL_RTO * 2, reliable_send.MAX_RTO))
end)

T.Test("Sender tolerates reordering shorter than the round trip", function()
	local sender = reliable_send.New()
	sender:AddRttSample(100)
	local early = entry()
	sender:OnSent(early, 0)

	for _ = 1, reliable_send.LOSS_THRESHOLD do
		local later = entry()
		sender:OnSent(later, 0)
		sender:OnAcked(later)
	end

	T(sender:CheckLost(early, 50))["=="](false)
	T(sender:CheckLost(early, 120))["=="](true)
end)

T.Test("Sender backs off the rto on timeouts until a new sample", function()
	local sender = reliable_send.New()
	sender:AddRttSample(100)
	local rto = sender.rto
	local e = entry()
	sender:OnSent(e, 0)
	T(sender:CheckLost(e, rto - 1))["=="](false)
	T(sender:CheckLost(e, rto))["=="](true)
	T(sender.rto)["=="](math.min(rto * 2, reliable_send.MAX_RTO))
	T(sender:CheckLost(e, rto + rto * 2 - 1))["=="](false)
	sender:AddRttSample(100)
	T(sender.rto)["<"](rto * 2)
end)

return {}

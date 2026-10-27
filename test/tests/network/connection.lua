local T = import("test/environment.lua")
local attest = import("goluwa/attest.lua")
local connection = import("goluwa/network/connection.lua")
local reliable_send = import("goluwa/network/reliable_send.lua")
local handshake = import("goluwa/network/handshake.lua")
local packet_header = import("goluwa/network/packet_header.lua")
local real_now = reliable_send.Now
local fake_ms = 1000000

local function make_pair(opts)
	opts = opts or {}
	local a_to_b = {}
	local b_to_a = {}
	local pair = {up = 0, down = 0}
	local client = connection.New(
		function(str)
			pair.up = pair.up + 1

			if opts.drop and opts.drop(str, "up") then return end

			table.insert(a_to_b, str)
		end,
		false
	)
	local server = connection.New(
		function(str)
			pair.down = pair.down + 1

			if opts.drop and opts.drop(str, "down") then return end

			table.insert(b_to_a, str)
		end,
		true
	)
	pair.client = client
	pair.server = server

	function pair.Step(ms)
		fake_ms = fake_ms + (ms or 10)
		local now = fake_ms / 1000
		local to_server = a_to_b
		local to_client = b_to_a
		a_to_b = {}
		b_to_a = {}

		if opts.reverse then
			local n = #to_server

			for i = 1, n / 2 do
				to_server[i], to_server[n - i + 1] = to_server[n - i + 1], to_server[i]
			end
		end

		for _, str in ipairs(to_server) do
			server:Receive(str, now)
		end

		for _, str in ipairs(to_client) do
			client:Receive(str, now)
		end

		client:Update(now)
		server:Update(now)
	end

	function pair.Run(count, ms)
		for _ = 1, count do
			pair.Step(ms)
		end
	end

	client.received = {}
	server.received = {}
	client.disconnected = nil
	server.disconnected = nil

	function client:OnReceive(payload, flags, channel)
		table.insert(client.received, {payload, flags, channel})
	end

	function server:OnReceive(payload, flags, channel)
		table.insert(server.received, {payload, flags, channel})
	end

	function client:OnDisconnect(code)
		client.disconnected = code
	end

	function server:OnDisconnect(code)
		server.disconnected = code
	end

	return pair
end

local function setup(opts)
	reliable_send.Now = function()
		return fake_ms
	end
	local pair = make_pair(opts)
	pair.client:Connect(fake_ms / 1000)
	return pair
end

local function teardown()
	reliable_send.Now = real_now
end

T.Test("Connection handshake connects both sides", function()
	local pair = setup()
	pair.Run(5)
	T(pair.client:IsConnected())["=="](true)
	T(pair.server:IsConnected())["=="](true)
	teardown()
end)

T.Test("Connection handshake survives lost request", function()
	local dropped = 0
	local pair = setup{
		drop = function(str, dir)
			if dir == "up" and dropped < 3 then
				dropped = dropped + 1
				return true
			end
		end,
	}
	pair.Run(300)
	T(dropped)["=="](3)
	T(pair.client:IsConnected())["=="](true)
	T(pair.server:IsConnected())["=="](true)
	teardown()
end)

T.Test("Connection fails when nobody answers", function()
	local pair = setup{
		drop = function()
			return true
		end,
	}
	pair.Run(800, 10)
	T(pair.client.disconnected)["=="](0)
	T(pair.client:IsConnected())["=="](false)
	teardown()
end)

T.Test("Connection queues sends made before the handshake finishes", function()
	local pair = setup()
	pair.client:Send("early", "reliable", 0)
	pair.Run(10)
	T(#pair.server.received)["=="](1)
	T(pair.server.received[1][1])["=="]("early")
	teardown()
end)

T.Test("Connection reliable delivery is ordered and complete with loss and reordering", function()
	math.randomseed(1234)
	local pair = setup{
		reverse = true,
		drop = function(str)
			return math.random() < 0.3
		end,
	}
	pair.Run(600)
	T(pair.client:IsConnected())["=="](true)

	for i = 1, 50 do
		pair.client:Send("msg" .. i, "reliable", 0)
		pair.Step(5)
	end

	pair.Run(2000, 10)
	T(#pair.server.received)["=="](50)

	for i = 1, 50 do
		T(pair.server.received[i][1])["=="]("msg" .. i)
	end

	teardown()
end)

T.Test("Connection fragments and reassembles large reliable messages", function()
	math.randomseed(99)
	local pair = setup{
		drop = function()
			return math.random() < 0.2
		end,
	}
	pair.Run(600)
	local big = string.rep("0123456789abcdef", 1000)
	pair.client:Send(big, "reliable", 2)
	pair.server:Send("back", "reliable", 0)
	pair.Run(2000, 10)
	T(#pair.server.received)["=="](1)
	T(pair.server.received[1][1] == big)["=="](true)
	T(pair.server.received[1][3])["=="](2)
	T(pair.client.received[1][1])["=="]("back")
	teardown()
end)

T.Test("Connection channels order independently", function()
	local pair = setup()
	pair.Run(5)
	pair.client:Send("a1", "reliable", 1)
	pair.client:Send("b1", "reliable", 2)
	pair.client:Send("a2", "reliable", 1)
	pair.Run(10)
	T(#pair.server.received)["=="](3)
	teardown()
end)

T.Test("Connection sequenced drops stale packets", function()
	local pair = setup()
	pair.Run(5)
	local server = pair.server
	local ch = pair.client:GetChannel(0)
	pair.client:Send("one", "sequenced", 0)
	pair.client:Send("two", "sequenced", 0)
	pair.Run(3)
	T(#server.received)["=="](2)
	local stale = packet_header.Prefix .. packet_header.EncodeRecord(packet_header.TYPE_DATA, packet_header.FLAG_UNRELIABLE_SEQUENCED, 0, 0, "stale")
	server:Receive(stale, fake_ms / 1000)
	T(#server.received)["=="](2)
	teardown()
end)

T.Test("Connection unreliable large payload errors", function()
	local pair = setup()
	pair.Run(5)

	attest.fails(
		function()
			pair.client:Send(string.rep("x", 5000), "unreliable", 0)
		end,
		"too big"
	)

	teardown()
end)

T.Test("Connection times out silent peers", function()
	local silent = false
	local pair = setup{
		drop = function()
			return silent
		end,
	}
	pair.Run(10)
	T(pair.server:IsConnected())["=="](true)
	silent = true
	pair.Run(1500, 10)
	T(pair.server.disconnected)["=="](0)
	T(pair.client.disconnected)["=="](0)
	teardown()
end)

T.Test("Connection explicit disconnect notifies the remote side", function()
	local pair = setup()
	pair.Run(5)
	pair.client:Disconnect(7, fake_ms / 1000)
	pair.Run(3)
	T(pair.server.disconnected)["=="](7)
	T(pair.server:IsConnected())["=="](false)
	teardown()
end)

T.Test("Connection measures ping", function()
	local pair = setup()
	pair.Run(10, 25)
	pair.client:Send("x", "reliable", 0)
	pair.Run(10, 25)
	T(pair.client.ping)[">"](0)
	teardown()
end)

local function records_of(datagram)
	local records = {}
	local pos = packet_header.PrefixSize + 1

	while pos <= #datagram do
		local type_, flags, channel, id, _, _, start, stop = packet_header.DecodeRecord(datagram, pos)
		records[#records + 1] = {
			type = type_,
			flags = flags,
			channel = channel,
			id = id,
			payload = datagram:sub(start, stop),
		}
		pos = stop + 1
	end

	return records
end

local function run_until(pair, done, steps, ms)
	for _ = 1, steps do
		if done() then return true end

		pair.Step(ms)
	end

	return done()
end

T.Test("Connection reliable channel keeps going when loss holds back more than the receive window", function()
	math.randomseed(77)
	local pair = setup{
		drop = function()
			return math.random() < 0.1
		end,
	}
	pair.Run(200)
	T(pair.client:IsConnected())["=="](true)
	local count = connection.RECEIVE_WINDOW * 3

	for i = 1, count do
		pair.client:Send("m" .. i, "reliable", 0)
	end

	T(
		run_until(
			pair,
			function()
				return #pair.server.received == count
			end,
			5000,
			10
		)
	)["=="](true)

	for i = 1, count do
		if pair.server.received[i][1] ~= "m" .. i then
			T(pair.server.received[i][1])["=="]("m" .. i)

			break
		end
	end

	T(pair.client:IsConnected())["=="](true)
	teardown()
end)

T.Test("Connection does not ack reliable records beyond the receive window", function()
	local acked = {}
	local pair = setup{
		drop = function(str, dir)
			if dir == "down" then
				for _, record in ipairs(records_of(str)) do
					if record.type == packet_header.TYPE_ACK then
						for i = 1, #record.payload, 2 do
							acked[record.payload:byte(i) + record.payload:byte(i + 1) * 256] = true
						end
					end
				end
			end
		end,
	}
	pair.Run(5)
	local far = connection.RECEIVE_WINDOW + 5
	pair.server:Receive(
		packet_header.Prefix .. packet_header.EncodeRecord(packet_header.TYPE_DATA, packet_header.FLAG_RELIABLE, 0, far, "too far"),
		fake_ms / 1000
	)
	pair.Run(3)
	T(acked[far])["=="](nil)
	T(#pair.server.received)["=="](0)
	pair.client:Send("first", "reliable", 0)
	pair.Run(3)
	T(acked[0])["=="](true)
	T(pair.server.received[1][1])["=="]("first")
	teardown()
end)

T.Test("Connection sends reliable messages larger than 255 fragments", function()
	local pair = setup()
	pair.Run(5)
	local big = string.rep("0123456789", math.ceil(connection.MAX_FRAGMENT * 300 / 10))
	pair.server:Send(big, "reliable", 1)
	T(
		run_until(pair, function()
			return #pair.client.received == 1
		end, 500, 10)
	)["=="](true)
	T(pair.client.received[1][1] == big)["=="](true)
	teardown()
end)

T.Test("Connection rejects oversized reliable payloads without breaking the channel", function()
	local pair = setup()
	pair.Run(5)
	pair.client:Send("before", "reliable", 0)
	local max_fragments = connection.MAX_FRAGMENTS
	connection.MAX_FRAGMENTS = 4

	attest.fails(
		function()
			pair.client:Send(string.rep("x", connection.MAX_FRAGMENT * 4 + 1), "reliable", 0)
		end,
		"too big"
	)

	connection.MAX_FRAGMENTS = max_fragments
	pair.client:Send("after", "reliable", 0)
	pair.Run(5)
	T(#pair.server.received)["=="](2)
	T(pair.server.received[1][1])["=="]("before")
	T(pair.server.received[2][1])["=="]("after")
	teardown()
end)

T.Test("Connection batches small messages and acks into few datagrams", function()
	local pair = setup()
	pair.Run(5)
	local up = pair.up
	local down = pair.down

	for i = 1, 200 do
		pair.client:Send("reliable " .. i, "reliable", 0)
		pair.client:Send("unreliable " .. i, "unreliable", 1)
	end

	pair.Run(3)
	T(#pair.server.received)["=="](400)
	T(pair.up - up)["<="](10)
	T(pair.down - down)["<="](3)
	teardown()
end)

T.Test("Connection retransmit timeout adapts to a slow round trip", function()
	local pair = setup()
	pair.Run(10, 300)
	local retransmitted = pair.client.stats.retransmitted

	for i = 1, 20 do
		pair.client:Send("slow " .. i, "reliable", 0)
		pair.Step(300)
	end

	pair.Run(10, 300)
	T(#pair.server.received)["=="](20)
	T(pair.client.stats.retransmitted)["=="](retransmitted)
	teardown()
end)

T.Test("Connection recovers a lost record before the retransmit timeout", function()
	local drop_next_data = false
	local pair = setup{
		drop = function(str, dir)
			if dir == "up" and drop_next_data then
				for _, record in ipairs(records_of(str)) do
					if record.type == packet_header.TYPE_DATA then
						drop_next_data = false
						return true
					end
				end
			end
		end,
	}
	pair.Run(5)
	drop_next_data = true
	pair.client:Send("lost", "reliable", 0)
	pair.Step(10)

	for i = 1, 4 do
		pair.client:Send("later " .. i, "reliable", 0)
		pair.Step(10)
	end

	T(drop_next_data)["=="](false)
	local elapsed = 0

	while #pair.server.received < 5 and elapsed < 1000 do
		pair.Step(10)
		elapsed = elapsed + 10
	end

	T(#pair.server.received)["=="](5)
	T(pair.server.received[1][1])["=="]("lost")
	T(elapsed)["<"](reliable_send.MIN_RTO)
	teardown()
end)

T.Test("Connection measures the round trip during the handshake", function()
	local pair = setup()
	pair.Run(4, 50)
	T(pair.client:IsConnected())["=="](true)
	T(pair.server:IsConnected())["=="](true)
	T(pair.client.sender.srtt)[">="](50)
	T(pair.server.sender.srtt)[">="](50)
	T(pair.client.sender.rto)["<"](reliable_send.INITIAL_RTO)
	teardown()
end)

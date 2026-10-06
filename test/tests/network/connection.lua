local T = import("test/environment.lua")
local attest = import("goluwa/attest.lua")
local connection = import("goluwa/network/connection.lua")
local reliable_send = import("goluwa/network/reliable_send.lua")
local handshake = import("goluwa/network/handshake.lua")
local real_now = reliable_send.Now
local fake_ms = 1000000

local function make_pair(opts)
	opts = opts or {}
	local a_to_b = {}
	local b_to_a = {}
	local client = connection.New(
		function(str)
			if opts.drop and opts.drop(str, "up") then return end

			table.insert(a_to_b, str)
		end,
		false
	)
	local server = connection.New(
		function(str)
			if opts.drop and opts.drop(str, "down") then return end

			table.insert(b_to_a, str)
		end,
		true
	)
	local pair = {client = client, server = server}

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
	local stale = import("goluwa/network/packet_header.lua").Encode(0, 2, 1, 0, 1, 1, "stale")
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

-- Simple HTTP test with debugging
require("goluwa.global_environment")
local http = require("http")
local system = require("system")
local event = require("event")
local sockets = require("sockets.sockets")
print("Testing HTTP GET to http://www.google.com/...")
local done = false
local client = http.Get("http://www.google.com/", function(data)
	print("\n✓ HTTP callback called!")
	print("Status:", data.code)
	print("Body length:", #data.body)
	done = true
	system.run = false
end)
print("Client created:", client)
print("Client type:", client.Type)
-- Add error handler
local orig_error = client.OnError
client.OnError = function(self, err, tr)
	print("\n✗ Socket error:", err)
	print(tr)
	system.run = false
	return orig_error(self, err, tr)
end
-- Add connect handler
local orig_connect = client.OnConnect
client.OnConnect = function(self)
	print("✓ Socket connected!")
	return orig_connect(self)
end
-- Run main loop
event.Call("Initialize")
local last_time = 0
local max_frames = 300
local time = require("bindings.time")

for i = 1, max_frames do
	local now = system.GetTime()
	local dt = now - (last_time or 0)
	system.SetFrameTime(dt)
	system.SetFrameNumber(i)
	system.SetElapsedTime(system.GetElapsedTime() + dt)
	event.Call("Update", dt)
	last_time = now

	if i % 30 == 1 then
		print(
			string.format(
				"Frame %d - connecting:%s connected:%s pool_size:%d",
				i,
				tostring(client.connecting),
				tostring(client.connected),
				sockets.pool.i - 1
			)
		)
	end

	if done or not system.run then break end

	-- Small sleep to allow network I/O
	time.sleep(0.001) -- 1ms
end

if not done then print("\n✗ Test failed - callback never called") end

event.Call("ShutDown")

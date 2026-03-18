return setmetatable(
	{},
	{
		__index = function(self, name)
			local backend = import("goluwa/websocket.server_" .. name)
			self[name] = backend
			return backend
		end,
	}
)

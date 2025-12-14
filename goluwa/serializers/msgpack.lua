local serializer = require("serializer")

serializer.AddLibrary(
	"msgpack",
	function(msgpack, val)
		return msgpack.encode(val)
	end,
	function(msgpack, val)
		return msgpack.decode(val)
	end,
	require("helpers.msgpack")
)

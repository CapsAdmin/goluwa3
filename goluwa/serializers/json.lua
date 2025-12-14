local serializer = require("serializer")

serializer.AddLibrary(
	"json",
	function(json, ...)
		return json.encode(...)
	end,
	function(json, ...)
		return json.decode(...)
	end,
	require("json")
)

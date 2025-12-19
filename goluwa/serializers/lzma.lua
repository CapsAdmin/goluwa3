local serializer = require("serializer")
local Buffer = require("structs.buffer")

serializer.AddLibrary(
	"lzma",
	nil,
	function(lib, str)
		local buf = Buffer.New(str, #str)
		return lib(buf):GetString()
	end,
	require("file_formats.lzma.decode")
)

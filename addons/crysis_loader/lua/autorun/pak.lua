local event = import("goluwa/event.lua")

event.AddListener("ZipDecrypt", "crysis_loader", function(method, data, crc32)
	if method == 6 then
		return import("lua/crysis_loader/cry_pak.lua").Decrypt(data, crc32)
	end
end)

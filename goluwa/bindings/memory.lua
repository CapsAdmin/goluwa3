local ffi = require("ffi")
local memory = {}
ffi.cdef[[
	void *malloc(size_t size);
	void *calloc(size_t count, size_t size);
	void *realloc(void *ptr, size_t size);
	void free(void *ptr);
	void* memcpy(void* dest, const void* src, size_t n);
	int memcmp(const void* lhs, const void* rhs, size_t n);
]]
memory.free = ffi.C.free
memory.realloc = ffi.C.realloc
memory.malloc = ffi.C.malloc
memory.memcpy = ffi.C.memcpy
memory.memcmp = ffi.C.memcmp

do
	local pointer_types = setmetatable({}, {__mode = "k"})

	-- outside the Lua heap: a big ffi.new adds its size to the collector's debt, which it pays with
	-- one long step. Zeroed, freed when the returned pointer is collected, keep that pointer alive.
	function memory.NewArray(ctype, count)
		local pointer_type = pointer_types[ctype]

		if not pointer_type then
			pointer_type = ffi.typeof("$*", ctype)
			pointer_types[ctype] = pointer_type
		end

		local pointer = ffi.C.calloc(count, ffi.sizeof(ctype))

		if pointer == nil then
			error("out of memory allocating " .. count .. " x " .. tostring(ctype), 2)
		end

		return ffi.gc(ffi.cast(pointer_type, pointer), ffi.C.free)
	end
end

return memory

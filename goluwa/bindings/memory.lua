local ffi = require("ffi")
local memory = {}
ffi.cdef[[
	void *malloc(size_t size);
	void *realloc(void *ptr, size_t size);
	void free(void *ptr);
	void* memcpy(void* dest, const void* src, size_t n);
]]
memory.free = ffi.C.free
memory.realloc = ffi.C.realloc
memory.malloc = ffi.C.malloc
memory.memcpy = ffi.C.memcpy
return memory

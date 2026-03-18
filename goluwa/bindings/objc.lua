-- https://github.com/mogenson/lua-utils/blob/main/objc.lua
local ffi = require("ffi")

local function table_pack(...)
	return {n = select("#", ...), ...}
end

local C = ffi.C
---@alias cdata  userdata C types returned from FFI
---@alias id     cdata    Objective-C object
---@alias Class  cdata    Objective-C Class
---@alias SEL    cdata    Objective-C Selector
---@alias Method cdata    Objective-C Method
ffi.cdef([[
// types
typedef signed char   BOOL;
typedef double        CGFloat;
typedef long          NSInteger;
typedef unsigned long NSUInteger;
typedef struct objc_class    *Class;
typedef struct objc_object   *id;
typedef struct objc_selector *SEL;
typedef struct objc_method   *Method;
typedef struct objc_property *objc_property_t;
typedef id                   (*IMP) (id, SEL, ...);
typedef struct CGPoint { CGFloat x; CGFloat y; } CGPoint;
typedef struct CGSize { CGFloat width; CGFloat height; } CGSize;
typedef struct CGRect { CGPoint origin; CGSize size; } CGRect;

// API
BOOL class_addMethod(Class cls, SEL name, IMP imp, const char *types);
Class objc_allocateClassPair(Class superclass, const char *name, size_t extraBytes);
Class objc_lookUpClass(const char *name);
Class object_getClass(id obj);
Method class_getClassMethod(Class cls, SEL name);
Method class_getInstanceMethod(Class cls, SEL name);
SEL sel_registerName(const char *str);
char * method_copyArgumentType(Method m, unsigned int index);
char * method_copyReturnType(Method m);
const char * class_getName(Class cls);
const char * object_getClassName(id obj);
const char * sel_getName(SEL sel);
objc_property_t class_getProperty(Class cls, const char *name);
unsigned int method_getNumberOfArguments(Method m);
void free(void *ptr);
void objc_msgSend(void);
void objc_registerClassPair(Class cls);
]])
assert(ffi.load("/usr/lib/libobjc.A.dylib", true))
local type_encoding = setmetatable(
	{
		["c"] = "char",
		["i"] = "int",
		["s"] = "short",
		["l"] = "long",
		["q"] = "NSInteger",
		["C"] = "unsigned char",
		["I"] = "unsigned int",
		["S"] = "unsigned short",
		["L"] = "unsigned long",
		["Q"] = "NSUInteger",
		["f"] = "float",
		["d"] = "double",
		["B"] = "BOOL",
		["v"] = "void",
		["*"] = "char*",
		["@"] = "id",
		["#"] = "Class",
		[":"] = "SEL",
		["^"] = "void*",
		["?"] = "void",
		["r*"] = "char*",
		["r^v"] = "const void*",
	},
	{
		__index = function(_, k)
			assert(type(k) == "string" and #k > 2)
			local first_letter = k:sub(1, 1)

			if first_letter == "{" or first_letter == "(" then -- named struct or union
				return assert(select(3, k:find("%" .. first_letter .. "(%a+)=")))
			end
		end,
		__newindex = nil, -- read only table
	}
)
local cast_cache = {}

---cast an object to C type using cached type
---@param typedef string C type definition
---@param object any object to cast
---@return cdata c
local function cast(typedef, object)
	local typeobj = cast_cache[typedef]

	if not typeobj then
		typeobj = ffi.typeof(typedef)
		cast_cache[typedef] = typeobj
	end

	return ffi.cast(typeobj, object)
end

---convert a NULL pointer to nil
---@param p cdata pointer
---@return cdata | nil
local function ptr(p)
	if p == nil then return nil else return p end
end

---return a Class from name or object
---@param name string | Class | id
---@return Class
local function cls(name)
	assert(name)

	if ffi.istype("id", name) then
		return assert(ptr(C.object_getClass(name))) -- get class from object
	end

	if type(name) == "cdata" and ffi.istype("Class", name) then
		return name -- already a Class
	end

	assert(type(name) == "string")
	return assert(ptr(C.objc_lookUpClass(name)))
end

---return SEL from name
---@param name string | SEL
---@return SEL
local function sel(name)
	assert(name)

	if type(name) == "cdata" and ffi.istype("SEL", name) then return name end

	assert(type(name) == "string")
	return C.sel_registerName(name)
end

---return Method for Class or object and SEL
---@param self Class | id
---@param selector SEL
---@return Method?
local function getMethod(self, selector) ---@diagnostic disable-line: redefined-local
	if ffi.istype("Class", self) then
		return assert(ptr(C.class_getClassMethod(self, selector)))
	elseif ffi.istype("id", self) then
		return assert(ptr(C.class_getInstanceMethod(cls(self), selector)))
	end

	assert(false, "self not a Class or object")
end

---convert a Lua variable to a C type if needed
---@param lua_var any
---@param c_type string
---@return cdata | any
local function convert(lua_var, c_type)
	if type(lua_var) == "string" and c_type == "char*" then
		return cast(c_type, lua_var)
	elseif type(lua_var) == "cdata" and c_type == "id" and ffi.istype("Class", lua_var) then
		return cast(c_type, lua_var)
	elseif lua_var == nil then
		return ffi.new(c_type)
	end

	return lua_var
end

---call a method for a SEL on a Class or object
---@param self Class | id the class or object
---@param selector SEL name of method
---@param ...? any additional method parameters
---@return any
local function msgSend(self, selector, ...)
	assert(type(self) == "cdata")
	local method = getMethod(self, selector)
	local call_args = table_pack(self, selector, ...)
	local char_ptr = assert(ptr(C.method_copyReturnType(method)))
	local objc_type = ffi.string(char_ptr)
	C.free(char_ptr)
	local c_type = assert(type_encoding[objc_type])
	local signature = {}
	table.insert(signature, c_type)
	table.insert(signature, "(*)(")
	local num_method_args = C.method_getNumberOfArguments(method)
	assert(num_method_args == call_args.n)

	for i = 1, num_method_args do
		char_ptr = assert(ptr(C.method_copyArgumentType(method, i - 1)))
		objc_type = ffi.string(char_ptr)
		C.free(char_ptr)
		c_type = assert(type_encoding[objc_type])
		table.insert(signature, c_type)
		call_args[i] = convert(call_args[i], c_type)

		if i < num_method_args then table.insert(signature, ",") end
	end

	table.insert(signature, ")")
	local fn = cast(table.concat(signature), C.objc_msgSend)
	return ptr(fn(unpack(call_args, 1, call_args.n)))
end

---load a Framework
---@param framework string framework name without the '.framework' extension
local function loadFramework(framework)
	-- on newer versions of MacOS this is a broken symbolic link, but dlopen() still succeeds
	assert(
		ffi.load(string.format("/System/Library/Frameworks/%s.framework/%s", framework, framework), true)
	)
end

---create a new custom class from an optional base class
---@param name string name of new class
---@param super_class? string | Class parent class, or NSObject if omitted
---@return Class
local function newClass(name, super_class)
	assert(name and type(name) == "string")
	local super_class = cls(super_class or "NSObject") ---@diagnostic disable-line: redefined-local
	local class = assert(ptr(C.objc_allocateClassPair(super_class, name, 0)))
	C.objc_registerClassPair(class)
	return class
end

---add a method to a custom class
---@param class string | Class class created with newClass()
---@param selector string | SEL name of method
---@param types string Objective-C type encoded method arguments and return type
---@param func function lua callback function for method implementation
---@return cdata ffi callback
local function addMethod(class, selector, types, func)
	assert(type(func) == "function")
	assert(type(types) == "string")
	local class = cls(class) ---@diagnostic disable-line: redefined-local
	local selector = sel(selector) ---@diagnostic disable-line: redefined-local
	local signature = {}
	table.insert(signature, type_encoding[types:sub(1, 1)]) -- return type
	table.insert(signature, "(*)(") -- anonymous function
	for i = 2, #types do
		table.insert(signature, type_encoding[types:sub(i, i)])

		if i < #types then table.insert(signature, ",") end
	end

	table.insert(signature, ")")
	local signature = table.concat(signature) ---@diagnostic disable-line: redefined-local
	local imp = cast("IMP", cast(signature, func))
	assert(C.class_addMethod(class, selector, imp, types) == 1)
	return imp
end

local objc = {
	Class = cls,
	SEL = sel,
	addMethod = addMethod,
	loadFramework = loadFramework,
	msgSend = msgSend,
	newClass = newClass,
	ptr = ptr,
}
local class_methods = {
	Call = function(class, selector, ...)
		return msgSend(class, sel(selector), ...)
	end,
}
local object_methods = {
	Call = function(object, selector, ...)
		return msgSend(object, sel(selector), ...)
	end,
	GetProperty = function(object, property_name)
		return msgSend(object, sel(property_name))
	end,
	SetProperty = function(object, property_name, value)
		local setter = string.format("set%s%s:", property_name:sub(1, 1):upper(), property_name:sub(2))
		msgSend(object, sel(setter), value)
	end,
}
ffi.metatype(
	"struct objc_selector",
	{
		__tostring = function(selector)
			return ffi.string(assert(ptr(C.sel_getName(selector))))
		end,
	}
)
ffi.metatype(
	"struct objc_class",
	{
		__tostring = function(class)
			return ffi.string(assert(ptr(C.class_getName(class))))
		end,
		__index = class_methods,
	}
)
ffi.metatype(
	"struct objc_object",
	{
		__tostring = function(class)
			return ffi.string(assert(ptr(C.object_getClassName(class))))
		end,
		__index = object_methods,
	}
)
return objc

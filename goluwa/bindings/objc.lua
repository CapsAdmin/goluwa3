-- https://github.com/mogenson/lua-utils/blob/main/objc.lua
local ffi = require("ffi")

local C = ffi.C
---@alias cdata  userdata C types returned from FFI
---@alias id     cdata    Objective-C object
---@alias Class  cdata    Objective-C Class
---@alias SEL    cdata    Objective-C Selector
ffi.cdef([[
// types
typedef signed char   BOOL;
typedef double        CGFloat;
typedef long          NSInteger;
typedef unsigned long NSUInteger;
typedef struct objc_class    *Class;
typedef struct objc_object   *id;
typedef struct objc_selector *SEL;
typedef id                   (*IMP) (id, SEL, ...);
typedef struct CGPoint { CGFloat x; CGFloat y; } CGPoint;
typedef struct CGSize { CGFloat width; CGFloat height; } CGSize;
typedef struct CGRect { CGPoint origin; CGSize size; } CGRect;

// API
BOOL class_addMethod(Class cls, SEL name, IMP imp, const char *types);
Class objc_allocateClassPair(Class superclass, const char *name, size_t extraBytes);
Class objc_lookUpClass(const char *name);
Class object_getClass(id obj);
SEL sel_registerName(const char *str);
const char * class_getName(Class cls);
const char * object_getClassName(id obj);
const char * sel_getName(SEL sel);
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
local bind_cache = {}
local cls
local ptr
local sel

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

local function parse_encoded_token(types, index)
	local token = types:sub(index, index)

	if token == "" then return nil, index end

	if token == "r" then
		local next_token, next_index = parse_encoded_token(types, index + 1)
		return token .. assert(next_token), next_index
	end

	if token == "^" then
		local next_token, next_index = parse_encoded_token(types, index + 1)
		return token .. assert(next_token), next_index
	end

	if token == "{" or token == "(" then
		local open = token
		local close = token == "{" and "}" or ")"
		local depth = 1
		local cursor = index + 1

		while cursor <= #types do
			local char = types:sub(cursor, cursor)

			if char == open then
				depth = depth + 1
			elseif char == close then
				depth = depth - 1

				if depth == 0 then return types:sub(index, cursor), cursor + 1 end
			end

			cursor = cursor + 1
		end

		error("unterminated Objective-C type encoding: " .. types)
	end

	return token, index + 1
end

local function parse_encoded_types(types)
	local out = {}
	local index = 1

	while index <= #types do
		local token
		token, index = parse_encoded_token(types, index)
		if token then table.insert(out, token) end
	end

	return out
end

local function objc_signature_to_c_signature(types)
	local tokens = parse_encoded_types(types)
	local signature = {}

	for i, token in ipairs(tokens) do
		signature[i] = assert(type_encoding[token], "unsupported Objective-C type encoding: " .. token)
	end

	return tokens, signature
end

local function to_lua_identifier(str)
	return (str:gsub("[^%w_]", "_"))
end

local function setter_name(property_name)
	return "set" .. property_name:sub(1, 1):upper() .. property_name:sub(2) .. ":"
end

local function generate_arg_setup(c_type, arg_name)
	if c_type == "char*" then
		return "local " .. arg_name .. "_buffer = " .. arg_name ..
			" ~= nil and ffi.new('char[?]', #" .. arg_name .. " + 1) or nil\n" ..
			"if " .. arg_name .. "_buffer ~= nil then ffi.copy(" .. arg_name .. "_buffer, " .. arg_name .. ") end\n" ..
			"local " .. arg_name .. "_value = " .. arg_name .. "_buffer ~= nil and cast(" .. string.format("%q", c_type) .. ", " .. arg_name .. "_buffer) or ffi.new(" .. string.format("%q", c_type) .. ")"
	end

	if c_type == "id" then
		return string.format(
			"local %s_value = %s == nil and ffi.new(%q) or (type(%s) == \"cdata\" and ffi.istype(%q, %s) and cast(%q, %s) or %s)",
			arg_name,
			arg_name,
			c_type,
			arg_name,
			"Class",
			arg_name,
			c_type,
			arg_name,
			arg_name
		)
	end

	return string.format(
		"local %s_value = %s == nil and ffi.new(%q) or %s",
		arg_name,
		arg_name,
		c_type,
		arg_name
	)
end

local function generate_bound_method(chunk_name, owner_name, receiver_expr, method_name, descriptor)
	local selector_name = descriptor.selector or method_name
	local tokens, c_types = objc_signature_to_c_signature(assert(descriptor.types, "missing types for " .. owner_name .. "." .. method_name))
	local return_type = c_types[1]
	local arg_count = #c_types - 3
	local receiver_type = c_types[2]
	local function_args = {}
	local arg_setup = {}
	local call_args = {receiver_expr, "selector"}

	for index = 2, #c_types do
		function_args[#function_args + 1] = c_types[index]
	end

	for index = 1, arg_count do
		local arg_name = "arg" .. index
		local c_type = c_types[index + 3]
		arg_setup[index] = generate_arg_setup(c_type, arg_name)
		call_args[#call_args + 1] = arg_name .. "_value"
	end

	local fn_signature = string.format(
		"%s(*)(%s)",
		return_type,
		table.concat(function_args, ",")
	)
	local params = {}

	for index = 1, arg_count do
		params[index] = "arg" .. index
	end

	local source = {}
	local local_name = to_lua_identifier(owner_name .. "_" .. method_name)
	source[#source + 1] = string.format("return function(cast, ptr, sel, cls, ffi, C)%s", "")
	source[#source + 1] = string.format("\nlocal fn = cast(%q, C.objc_msgSend)", fn_signature)
	source[#source + 1] = string.format("\nlocal selector = sel(%q)", selector_name)

	if descriptor.kind == "class" and not descriptor.unbound then
		source[#source + 1] = string.format("\nlocal receiver = cls(%q)", owner_name)
		source[#source + 1] = string.format("\nreturn function(%s)", table.concat(params, ", "))
	else
		source[#source + 1] = string.format("\nreturn function(self%s%s)", arg_count > 0 and ", " or "", table.concat(params, ", "))
	end

	for _, line in ipairs(arg_setup) do
		source[#source + 1] = "\n" .. line
	end

	local call_receiver = descriptor.kind == "class" and (descriptor.unbound and "self" or "receiver") or "self"
	local invocation = {call_receiver, "selector"}

	for index = 1, arg_count do
		invocation[#invocation + 1] = "arg" .. index .. "_value"
	end

	if tokens[1] == "@" then
		source[#source + 1] = string.format("\nreturn ptr(fn(%s))", table.concat(invocation, ", "))
	else
		source[#source + 1] = string.format("\nreturn fn(%s)", table.concat(invocation, ", "))
	end

	source[#source + 1] = "\nend\nend"
	local source_text = table.concat(source)
	bind_cache[chunk_name .. ":" .. local_name] = source_text
	local factory = assert(load(source_text, chunk_name .. ":" .. local_name, "t"))()
	return factory(cast, ptr, sel, cls, ffi, C), receiver_type
end

local function bind(definition)
	assert(type(definition) == "table")
	local bindings = {
		classes = {},
		methods = {},
		props = {},
	}
	local class_names = definition.classes or {}
	local function resolve_class_if_available(class_name)
		local ok, value = pcall(cls, class_name)

		if ok then bindings.classes[class_name] = value end
	end

	for _, class_name in ipairs(class_names) do
		bindings.classes[class_name] = cls(class_name)
	end

	for class_name, groups in pairs(definition.methods or {}) do
		bindings.methods[class_name] = bindings.methods[class_name] or {}

		if bindings.classes[class_name] == nil then resolve_class_if_available(class_name) end

		for method_name, descriptor in pairs(groups.class or {}) do
			if type(descriptor) == "string" then descriptor = {types = descriptor} end
			descriptor.kind = "class"
			bindings.methods[class_name][method_name] = generate_bound_method(
				"objc.bind",
				class_name,
				"receiver",
				method_name,
				descriptor
			)
		end

		for method_name, descriptor in pairs(groups.instance or {}) do
			if type(descriptor) == "string" then descriptor = {types = descriptor} end
			descriptor.kind = "instance"
			bindings.methods[class_name][method_name] = generate_bound_method(
				"objc.bind",
				class_name,
				"self",
				method_name,
				descriptor
			)
		end
	end

	for class_name, properties in pairs(definition.props or {}) do
		bindings.props[class_name] = bindings.props[class_name] or {}

		for property_name, descriptor in pairs(properties) do
			if type(descriptor) == "string" then descriptor = {get = descriptor} end
			local prop = {}

			if descriptor.get then
				local getter = {selector = descriptor.selector or property_name, types = descriptor.get, kind = "instance"}
				prop.get = generate_bound_method("objc.bind", class_name, "self", property_name, getter)
			end

			if descriptor.set then
				local setter = {selector = descriptor.setter or setter_name(property_name), types = descriptor.set, kind = "instance"}
				prop.set = generate_bound_method("objc.bind", class_name, "self", setter.selector, setter)
			end

			bindings.props[class_name][property_name] = prop
		end
	end

	return bindings
end

---convert a NULL pointer to nil
---@param p cdata pointer
---@return cdata | nil
function ptr(p)
	if p == nil then return nil else return p end
end

---return a Class from name or object
---@param name string | Class | id
---@return Class
function cls(name)
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
function sel(name)
	assert(name)

	if type(name) == "cdata" and ffi.istype("SEL", name) then return name end

	assert(type(name) == "string")
	return C.sel_registerName(name)
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
	bind = bind,
	bind_cache = bind_cache,
	loadFramework = loadFramework,
	newClass = newClass,
	["nil"] = ffi.cast("id", 0),
	ptr = ptr,
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
	}
)
ffi.metatype(
	"struct objc_object",
	{
		__tostring = function(class)
			return ffi.string(assert(ptr(C.object_getClassName(class))))
		end,
	}
)
return objc

local data_schema = {}

local function resolve(value)
	if type(value) == "function" then return value() end

	return value
end

function data_schema.GetField(schema, parent_key, key)
	if not schema then return end

	local fields = schema.Fields
	local specific = fields[tostring(parent_key) .. "." .. tostring(key)]

	if specific then return specific end

	if type(key) == "number" then return fields[tostring(parent_key) .. "[]"] end

	return fields[key] or fields[tostring(parent_key) .. ".*"]
end

function data_schema.GetOptions(field)
	return field.Options and resolve(field.Options)
end

function data_schema.Exists(schema, ref, name)
	local list = resolve(schema.Refs[ref])

	for i = 1, #list do
		if list[i] == name then return true end
	end

	return false
end

function data_schema.Check(schema, data)
	local problems = {}

	local function walk(value, path, parent_key)
		for key, child in pairs(value) do
			local item_path = path .. "/" .. tostring(key)
			local field = data_schema.GetField(schema, parent_key, key)

			if field and field.Ref then
				if type(child) == "string" then
					if not data_schema.Exists(schema, field.Ref, child) then
						problems[#problems + 1] = item_path .. ": unknown " .. field.Ref .. " " .. child
					end
				end
			end

			if type(child) == "table" then
				walk(child, item_path, type(key) == "number" and parent_key or key)
			end
		end
	end

	walk(data, "", "")
	table.sort(problems)
	return problems
end

return data_schema

local objects = import("goluwa/objects/objects.lua")
objects.linked_objects = objects.linked_objects or {}

function objects.AddPropertyLink(...)
	local args = {...}
	args.n = select("#", ...)

	event.AddListener("Update", "update_object_properties", function()
		for i = #objects.linked_objects, 1, -1 do
			local data = objects.linked_objects[i]

			if type(data.args[1]) == "table" and type(data.args[2]) == "table" then
				local obj_a = data.args[1]
				local obj_b = data.args[2]
				local field_a = data.args[3]
				local field_b = data.args[4]
				local key_a = data.args[5]
				local key_b = data.args[6]

				if obj_a:IsValid() and obj_b:IsValid() then
					local info_a = obj_a.objects_variables and obj_a.objects_variables[field_a]
					local info_b = obj_b.objects_variables and obj_b.objects_variables[field_b]

					if info_a and info_b then
						if key_a and key_b then
							-- local val = a:GeFieldA().key_a
							-- val.key_a = b:GetFieldB().key_b
							-- a:SetFieldA(val)
							local val = obj_a[info_a.get_name](obj_a)
							val[key_a] = obj_b[info_b.get_name](obj_b)[key_b]

							if data.store.last_val ~= val then
								obj_a[info_a.set_name](obj_a, val)
								data.store.last_val = val
							end
						elseif key_a and not key_b then
							-- local val = a:GeFieldA()
							-- val.key_a = b:GetFieldB()
							-- a:SetFieldA(val)
							local val = obj_a[info_a.get_name](obj_a)
							val[key_a] = obj_b[info_b.get_name](obj_b)

							if data.store.last_val ~= val then
								obj_a[info_a.set_name](obj_a, val)
								data.store.last_val = val
							end
						elseif key_b and not key_a then
							-- local val = b:GeFieldB().key_b
							-- a:SetFieldA(val)
							local val = obj_b[info_b.get_name](obj_b)[key_b]

							if data.store.last_val ~= val then
								obj_a[info_a.set_name](obj_a, val)
								data.store.last_val = val
							end
						else
							-- local val = b:GeFieldB()
							-- a:SetFieldA(val)
							local val = obj_b[info_b.get_name](obj_b)

							if data.store.last_val ~= val then
								obj_a[info_a.set_name](obj_a, val)
								data.store.last_val = val
							end
						end
					end

					if not info_b then
						wlog("unable to find property info for %s (%s)", field_b, obj_b)
					end
				else
					list.remove(objects.linked_objects, i)
				end
			elseif type(data.args[2]) == "function" and type(data.args[3]) == "function" then
				local obj = data.args[1]
				local get_func = data.args[2]
				local set_func = data.args[3]

				if obj:IsValid() then
					local val = get_func()

					if data.store.last_val ~= val then
						set_func(val)
						data.store.last_val = val
					end
				else
					list.remove(objects.linked_objects, i)
				end
			end
		end
	end)

	list.insert(objects.linked_objects, {store = table.weak(), args = args})
end

function objects.RemovePropertyLink(obj_a, obj_b, field_a, field_b, key_a, key_b)
	for i, v in ipairs(objects.linked_objects) do
		local a = v.args

		if
			a[1] == obj_a and
			a[2] == obj_b and
			a[3] == field_a and
			a[4] == field_b and
			a[5] == key_a and
			a[6] == key_b
		then
			list.remove(objects.linked_objects, i)

			break
		end
	end
end

function objects.RemovePropertyLinks(obj)
	for i, v in pairs(objects.linked_objects) do
		if v.args[1] == obj or v.args[2] == obj then
			objects.linked_objects[i] = nil
		end
	end

	list.fix_indices(objects.linked_objects)
end

function objects.GetPropertyLinks(obj)
	local out = {}

	for _, v in ipairs(objects.linked_objects) do
		if v.args[1] == obj or v.args[2] == obj then
			list.insert(out, {unpack(v.args)})
		end
	end

	return out
end

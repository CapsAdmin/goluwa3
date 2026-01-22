local gui = require("gui.gui")
local system = require("system")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Ang3 = require("structs.ang3")
local Color = require("structs.color")
local META = ...

do -- animations
	-- these are useful for animations
	META:GetSet("DrawSizeOffset", Vec2(0, 0), {callback = "InvalidateMatrices"})
	META:GetSet("DrawScaleOffset", Vec2(1, 1), {callback = "InvalidateMatrices"})
	META:GetSet("DrawPositionOffset", Vec2(0, 0), {callback = "InvalidateMatrices"})
	META:GetSet("DrawAngleOffset", Ang3(0, 0, 0), {callback = "InvalidateMatrices"})
	META:GetSet("DrawColor", Color(0, 0, 0, 0))
	META:GetSet("DrawAlpha", 1)
	local parent_layout = {
		Size = true,
		Position = true,
		Rotation = true,
	}

	local function get_value(v, self)
		if type(v) == "table" and v.__lsx_value then return v.__lsx_value(self) end

		if type(v) == "function" then return v(self) end

		return v
	end

	local function lerp_linear(values, alpha, self)
		local count = #values

		if count <= 1 then return get_value(values[1], self) end

		local segment_count = count - 1
		local total_alpha = alpha * segment_count
		local segment_index = math.floor(total_alpha) + 1
		local segment_alpha = total_alpha - math.floor(total_alpha)

		if segment_index >= count then return get_value(values[count], self) end

		local v1 = get_value(values[segment_index], self)
		local v2 = get_value(values[segment_index + 1], self)

		if type(v1) == "number" then
			return math.lerp(segment_alpha, v1, v2)
		else
			return v1:GetLerped(segment_alpha, v2)
		end
	end

	local function lerp_bezier(values, alpha, self)
		local tbl = {}

		for i = 1, #values - 1 do
			local v1 = get_value(values[i], self)
			local v2 = get_value(values[i + 1], self)

			if type(v1) == "number" then
				tbl[i] = math.lerp(alpha, v1, v2)
			else
				tbl[i] = v1:GetLerped(alpha, v2)
			end
		end

		if #tbl > 1 then return lerp_bezier(tbl, alpha, self) else return tbl[1] end
	end

	function META:CalcAnimations()
		for i, animation in ipairs(self.animations) do
			local pause = false

			for i, v in ipairs(animation.pausers) do
				if animation.alpha >= v.alpha then
					if v.check(self) then
						pause = true
					else
						list.remove(animation.pausers, i)

						break
					end
				end
			end

			if not pause then
				animation.alpha = animation.alpha + system.GetFrameTime() / animation.time
			end

			local alpha = math.min(animation.alpha, 1)
			local val
			local to = animation.to

			if animation.pow then alpha = alpha ^ animation.pow end

			local interpolated_alpha = alpha

			if type(animation.interpolation) == "function" then
				interpolated_alpha = animation.interpolation(alpha)
			end

			if animation.interpolation == "bezier" then
				val = lerp_bezier(to, interpolated_alpha, self)
			else
				val = lerp_linear(to, interpolated_alpha, self)
			end

			if val == false then return end

			animation.func(self, val)

			if parent_layout[animation.var] then
				if self:HasParent() and not self.Parent:IsWorld() then
					self.Parent:CalcLayoutInternal(true)
				else
					self:CalcLayoutInternal(true)
				end
			elseif animation.var:sub(1, 4) ~= "Draw" then
				-- if it's not a Draw property, we should still probably trigger a layout update
				-- but maybe only for specific properties? Let's keep it for now but skip Draw*
				self:CalcLayoutInternal(true)
			end

			if alpha >= 1 and not pause then
				if animation.callback then
					if animation.callback(self) ~= false then
						animation.func(self, animation.from)
					end
				else
					animation.func(self, animation.from)
				end

				list.remove(self.animations, i)

				break
			else

			--self:MarkCacheDirty()
			end
		end
	end

	function META:StopAnimations()
		for _, animation in ipairs(self.animations) do
			if animation.callback then
				if animation.callback(self) ~= false then
					animation.func(self, animation.from)
				end
			else
				animation.func(self, animation.from)
			end
		end

		list.clear(self.animations)
		self:UpdateAnimations()
	end

	function META:IsAnimating()
		return #self.animations ~= 0
	end

	function META:Animate(config)
		local var = config.var
		local to = config.to
		local time = config.time
		local operator = config.operator
		local pow = config.pow
		local set = config.set
		local callback = config.callback
		local interpolation = config.interpolation or "linear"
		local original_val = type(self[var]) == "number" and self[var] or self[var]:Copy()
		local base = original_val

		for i, v in ipairs(self.animations) do
			if v.var == var then
				if operator then base = v.base or v.from end

				list.remove(self.animations, i)

				break
			end
		end

		local from = original_val

		if type(to) ~= "table" then
			to = {to}
		else
			local copy = {}

			for k, v in pairs(to) do
				copy[k] = v
			end

			to = copy
		end

		local pausers = {}

		for i, v in pairs(to) do
			if type(v) == "table" and v.__lsx_pauser then
				to[i] = nil
				list.insert(pausers, {check = v.__lsx_pauser, alpha = (i - 1) / (table.count(to) + #pausers)})
			elseif type(v) == "function" then
				to[i] = nil
				list.insert(pausers, {check = v, alpha = (i - 1) / (table.count(to) + #pausers)})
			end
		end

		list.fix_indices(to)

		for i, v in ipairs(to) do
			if v == "from" then
				to[i] = from
			else
				if operator then
					if operator == "+" then
						v = base + v
					elseif operator == "-" then
						v = base - v
					elseif operator == "^" then
						v = base ^ v
					elseif operator == "*" then
						v = base * v
					elseif operator == "/" then
						v = base / v
					elseif operator == "=" then

					end
				end

				to[i] = v
			end
		end

		if not set then
			if #to == 1 and to[1] == from then

			-- don't insert if it's already there
			else
				list.insert(to, 1, from)
			end
		end

		list.insert(
			self.animations,
			{
				operator = operator,
				base = base,
				from = from,
				to = to,
				time = time or 0.25,
				var = var,
				func = self["Set" .. var],
				start_time = system.GetElapsedTime(),
				pow = pow,
				callback = callback,
				pausers = pausers,
				interpolation = interpolation,
				alpha = 0,
			}
		)
	end
end

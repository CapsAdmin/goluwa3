--[[HOTRELOAD
	package.loaded["gui.base_surface"] = nil
	require("goluwa.gui.base_surface")
]]
local gui = require("gui.gui")
local system = require("system")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Ang3 = require("structs.ang3")
local Color = require("structs.color")
local easing = require("helpers.easing")
local spring = require("helpers.spring")
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

	local function lerp_linear(values, alpha, self, interpolation)
		local count = #values

		if count <= 1 then return get_value(values[1], self) end

		local segment_count = count - 1
		local total_alpha = alpha * segment_count
		local segment_index = math.floor(total_alpha) + 1
		local segment_alpha = total_alpha - math.floor(total_alpha)

		if segment_index >= count then
			segment_index = count - 1
			segment_alpha = total_alpha - (count - 2)
		elseif segment_index < 1 then
			segment_index = 1
			segment_alpha = total_alpha
		end

		if interpolation then segment_alpha = interpolation(segment_alpha) end

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

			for j = #animation.pausers, 1, -1 do
				local v = animation.pausers[j]

				if animation.alpha >= v.alpha then
					if v.check(self) then
						pause = true
					else
						list.remove(animation.pausers, j)
					end
				end
			end

			if not pause then
				animation.alpha = animation.alpha + system.GetFrameTime() / animation.time
			end

			local alpha = math.min(animation.alpha, 1)

			-- If we are paused at the end of a segment, check if we should skip to the next
			if pause and alpha < 1 then
				local segment_count = #animation.to - 1
				local local_alpha = (alpha * segment_count) % 1
				local current_segment = math.floor(alpha * segment_count) + 1
			-- If we're effectively at the end of the segment (alpha=1.0 for this segment)
			-- but we're paused, and the pauser says we can continue, we should jump
			-- However, the CalcAnimations loop already handles pause removal.
			-- The issue is that we are STUCK at this alpha.
			end

			if
				animation.spring_on_complete and
				animation.alpha >= animation.spring_on_complete_alpha and
				not animation.spring_on_complete_called
			then
				animation.spring_on_complete(self)
				animation.spring_on_complete_called = true
			end

			-- check if we are in a pause segment and the spring has visually settled enough to skip the rest of the settling duration
			if animation.is_spring and pause and animation.alpha < 1 then
				local segment_count = #animation.to - 1
				local local_alpha = (animation.alpha * segment_count) % 1

				if local_alpha > 0.4 then
					animation.alpha = (math.floor(animation.alpha * segment_count) + 1) / segment_count
				end
			end

			local alpha = math.min(animation.alpha, 1)
			local val
			local to = animation.to

			if animation.pow then alpha = alpha ^ animation.pow end

			local interpolated_alpha = alpha

			if animation.is_spring then
				if animation.interpolation == "bezier" then
					val = lerp_bezier(to, interpolated_alpha, self)
				else
					local total_duration = animation.time
					local segment_count = #to - 1
					local segment_duration = total_duration / segment_count
					val = lerp_linear(
						to,
						alpha,
						self,
						function(a)
							return animation.interpolation(a, segment_duration)
						end
					)
				end
			else
				if type(animation.interpolation) == "function" then
					interpolated_alpha = animation.interpolation(alpha)
				elseif type(animation.interpolation) == "string" and easing[animation.interpolation] then
					interpolated_alpha = easing[animation.interpolation](alpha)
				end

				if animation.interpolation == "bezier" then
					val = lerp_bezier(to, interpolated_alpha, self)
				else
					val = lerp_linear(to, interpolated_alpha, self)
				end
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
				if animation.callback then animation.callback(self) end

				list.remove(self.animations, i)

				break
			else

			--self:MarkCacheDirty()
			end
		end
	end

	function META:StopAnimations()
		table.clear(self.animations)
	end

	function META:IsAnimating(var)
		if not var then return #self.animations ~= 0 end

		for _, animation in ipairs(self.animations) do
			if animation.var == var then return true end
		end

		return false
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
		local original_val = type(self["Get" .. var]) == "function" and self["Get" .. var](self) or self[var]

		if type(original_val) == "table" and original_val.Copy then
			original_val = original_val:Copy()
		end

		local base = nil
		local inherited_velocity

		for i = #self.animations, 1, -1 do
			local v = self.animations[i]

			if v.var == var then
				if operator then base = v.base end

				if v.is_spring and v.alpha < 1 then
					local total_alpha = v.alpha * (#v.to - 1)
					local segment_index = math.floor(total_alpha) + 1
					local local_alpha = total_alpha - math.floor(total_alpha)

					if local_alpha < 0.0001 and total_alpha > 0.0001 then
						segment_index = segment_index - 1
						local_alpha = 1
					end

					local v1 = get_value(v.to[segment_index], self)
					local v2 = get_value(v.to[segment_index + 1], self)
					local delta = v2 - v1
					local total_duration = v.time
					local segment_count = #v.to - 1
					local segment_duration = total_duration / segment_count

					if v.velocity_solver then
						inherited_velocity = v.velocity_solver(local_alpha, segment_duration) * delta
					end
				end

				list.remove(self.animations, i)

				break
			end
		end

		if not base then
			if var == "DrawScaleOffset" and (operator == "*" or operator == "/") then
				base = Vec2(1, 1)
			else
				base = original_val
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

		local original_count = #to
		local pausers = {}
		local real_to_indices = {}
		local offset = 0

		for i = 1, original_count do
			local v = to[i]

			if (type(v) == "table" and v.__lsx_pauser) or type(v) == "function" then
				local check = type(v) == "function" and v or v.__lsx_pauser
				list.insert(pausers, {check = check, segment_index = i - 1 - offset})
				to[i] = nil
				offset = offset + 1
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
			local is_redundant = false

			-- Check if we should insert 'from' at the beginning
			-- or if the first target in 'to' is already 'from'
			if #to > 0 then
				local first = get_value(to[1], self)

				if type(first) == "number" and type(from) == "number" then
					if math.abs(first - from) < 0.001 then is_redundant = true end
				elseif type(first) == "table" and first.Distance then
					if first:Distance(from) < 0.001 then is_redundant = true end
				elseif type(first) == "table" and first.x then -- Vec2/Vec3 check without Distance method
					local distSq = (first.x - from.x) ^ 2 + (first.y - from.y) ^ 2

					if first.z and from.z then distSq = distSq + (first.z - from.z) ^ 2 end

					if distSq < 0.0001 then is_redundant = true end
				end
			end

			if not is_redundant then
				list.insert(to, 1, from)

				for _, p in ipairs(pausers) do
					p.segment_index = p.segment_index + 1
				end
			end
		end

		local spring_on_complete
		local spring_on_complete_alpha
		local is_spring = false
		local spring_duration
		local velocity_solver

		if type(interpolation) == "table" and interpolation.type == "spring" then
			if inherited_velocity then
				local v1 = get_value(to[1], self)
				local v2 = get_value(to[2], self)

				if v1 and v2 then
					local delta = v2 - v1

					if type(delta) == "number" and math.abs(delta) > 0.0001 then
						interpolation.velocity = inherited_velocity / delta
					elseif
						type(delta) == "table" and
						delta.GetLengthSquared and
						delta:GetLengthSquared() > 0.0001
					then
						interpolation.velocity = inherited_velocity:GetLength() / delta:GetLength()

						-- sign check? progress is 0..1, so if current vel is same direction as target, pos velocity
						if delta:GetDot(inherited_velocity) < 0 then
							interpolation.velocity = -interpolation.velocity
						end
					end
				end
			end

			local func, duration, v_func = spring.Create(interpolation)
			spring_on_complete = interpolation.onComplete or interpolation.onCompete
			interpolation = func
			spring_duration = duration
			is_spring = true
			velocity_solver = v_func
		end

		local segment_count = #to - 1

		if segment_count > 0 then
			for _, p in ipairs(pausers) do
				p.alpha = math.max(0, (p.segment_index - 1) / segment_count)
			end
		else
			for _, p in ipairs(pausers) do
				p.alpha = 0
			end
		end

		if is_spring then
			local segment_duration = (config.time or spring_duration)
			time = segment_duration * math.max(1, segment_count)

			if spring_on_complete then
				local perceived_duration = (config.interpolation.duration or 628) / 1000
				spring_on_complete_alpha = (
						math.max(1, segment_count) - 1 + math.min(perceived_duration / spring_duration, 0.99)
					) / math.max(1, segment_count)
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
				spring_on_complete = spring_on_complete,
				spring_on_complete_alpha = spring_on_complete_alpha,
				is_spring = is_spring,
				velocity_solver = velocity_solver,
				alpha = 0,
			}
		)
	end
end

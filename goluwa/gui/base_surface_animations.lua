local gui = require("gui.gui")
local system = require("system")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Ang3 = require("structs.ang3")
local Color = require("structs.color")
local META = ...

do -- animations
	-- these are useful for animations
	META:GetSet("DrawSizeOffset", Vec2(0, 0))
	META:GetSet("DrawScaleOffset", Vec2(1, 1))
	META:GetSet("DrawPositionOffset", Vec2(0, 0))
	META:GetSet("DrawAngleOffset", Ang3(0, 0, 0))
	META:GetSet("DrawColor", Color(0, 0, 0, 0))
	META:GetSet("DrawAlpha", 1)
	local parent_layout = {
		DrawSizeOffset = true,
		DrawScaleOffset = true,
		DrawAngleOffset = true,
		DrawPositionOffset = true,
		Size = true,
		Position = true,
		Angle = true,
	}

	local function lerp_values(values, alpha)
		local tbl = {}

		for i = 1, #values - 1 do
			if type(values[i]) == "number" then
				tbl[i] = math.lerp(alpha, values[i], values[i + 1])
			else
				tbl[i] = values[i]:GetLerped(alpha, values[i + 1])
			end
		end

		if #tbl > 1 then return lerp_values(tbl, alpha) else return tbl[1] end
	end

	function META:CalcAnimations()
		for i, animation in ipairs(self.animations) do
			local pause = false

			for i, v in ipairs(animation.pausers) do
				if animation.alpha >= v.alpha then
					if v.check() then
						pause = true
					else
						list.remove(animation.pausers, i)

						break
					end
				end
			end

			if not pause then
				animation.alpha = animation.alpha + system.GetFrameTime() / animation.time
				local alpha = animation.alpha
				local val
				local from = animation.from
				local to = animation.to

				if animation.pow then alpha = alpha ^ animation.pow end

				val = lerp_values(to, alpha)

				if val == false then return end

				animation.func(self, val)

				if parent_layout[animation.var] and self:HasParent() and not self.Parent:IsWorld() then
					self.Parent:CalcLayoutInternal(true)
				else
					self:CalcLayoutInternal(true)
				end

				if alpha >= 1 then
					if animation.callback then
						if animation.callback(self) ~= false then
							animation.func(self, from)
						end
					else
						animation.func(self, from)
					end

					list.remove(self.animations, i)

					break
				else

				--self:MarkCacheDirty()
				end
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

		for _, v in ipairs(self.animations) do
			if v.var == var then
				v.alpha = 0
				return
			end
		end

		local from = type(self[var]) == "number" and self[var] or self[var]:Copy()

		if type(to) ~= "table" then to = {to} end

		local pausers = {}

		for i, v in pairs(to) do
			if type(v) == "function" then
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
						v = from + v
					elseif operator == "-" then
						v = from - v
					elseif operator == "^" then
						v = from ^ v
					elseif operator == "*" then
						v = from * v
					elseif operator == "/" then
						v = from / v
					elseif operator == "=" then

					end
				end

				to[i] = v
			end
		end

		if not set then list.insert(to, 1, from) end

		list.insert(
			self.animations,
			{
				operator = operator,
				from = from,
				to = to,
				time = time or 0.25,
				var = var,
				func = self["Set" .. var],
				start_time = system.GetElapsedTime(),
				pow = pow,
				callback = callback,
				pausers = pausers,
				alpha = 0,
			}
		)
	end
end

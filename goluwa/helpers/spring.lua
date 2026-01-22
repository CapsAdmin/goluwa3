local spring = {}

local function solve_spring(m, k, c, v0)
	local zeta = c / (2 * math.sqrt(m * k))
	local w0 = math.sqrt(k / m)

	if zeta < 1 then
		local wd = w0 * math.sqrt(1 - zeta * zeta)
		local solve = function(t)
			local envelope = math.exp(-zeta * w0 * t)
			return 1 - envelope * (math.cos(wd * t) + ((zeta * w0 - v0) / wd) * math.sin(wd * t))
		end
		local velocity = function(t)
			local envelope = math.exp(-zeta * w0 * t)
			local cos_wd_t = math.cos(wd * t)
			local sin_wd_t = math.sin(wd * t)
			local C = (zeta * w0 - v0) / wd
			return envelope * ((zeta * w0 - wd * C) * cos_wd_t + (zeta * w0 * C + wd) * sin_wd_t)
		end
		return solve, velocity
	elseif zeta == 1 then
		local solve = function(t)
			return 1 - math.exp(-w0 * t) * (1 + (w0 - v0) * t)
		end
		local velocity = function(t)
			local envelope = math.exp(-w0 * t)
			local C = w0 - v0
			return envelope * (w0 * (1 + C * t) - C)
		end
		return solve, velocity
	else
		local w_n = math.sqrt(zeta * zeta - 1)
		local r1 = w0 * (-zeta + w_n)
		local r2 = w0 * (-zeta - w_n)
		local solve = function(t)
			return 1 - (
					(
						r2 - v0
					) / (
						r2 - r1
					) * math.exp(r1 * t) + (
						v0 - r1
					) / (
						r2 - r1
					) * math.exp(r2 * t)
				)
		end
		local velocity = function(t)
			return -(
				(
					r2 - v0
				) / (
					r2 - r1
				) * r1 * math.exp(r1 * t) + (
					v0 - r1
				) / (
					r2 - r1
				) * r2 * math.exp(r2 * t)
			)
		end
		return solve, velocity
	end
end

local function calculate_settling_duration(m, k, c, v0, epsilon)
	local zeta = c / (2 * math.sqrt(m * k))
	local w0 = math.sqrt(k / m)
	epsilon = epsilon or 0.03

	if zeta < 1 then
		-- envelope is exp(-zeta * w0 * t)
		-- exp(-zeta * w0 * t) < epsilon
		-- -zeta * w0 * t < ln(epsilon)
		-- t > -ln(epsilon) / (zeta * w0)
		if zeta == 0 then return 10 end -- avoid division by zero for undamped
		return -math.log(epsilon) / (zeta * w0)
	else
		-- for overdamped or critically damped, it settles faster or similar
		-- using the slower decay rate
		local r = 0

		if zeta == 1 then
			r = w0
		else
			r = w0 * (zeta - math.sqrt(zeta * zeta - 1))
		end

		return -math.log(epsilon) / r
	end
end

function spring.Create(config)
	local m = config.mass or 1
	local k = config.stiffness or 100
	local c = config.damping or 10
	local v0 = config.velocity or 0

	if config.bounce ~= nil or config.duration ~= nil then
		-- Map perceived parameters to physics parameters
		-- Based on a common mapping used in many libraries
		-- Default bounce 0.5, duration 628ms (approx 2*pi*100)
		local bounce = config.bounce or 0.5

		if bounce > 1 then bounce = 1 end

		if bounce < -0.99 then bounce = -0.99 end

		local duration = (config.duration or 628) / 1000 -- convert to seconds
		-- Using the formula:
		-- bounce = 1 - damping_ratio
		-- duration = settling_time or period-like value
		-- AnimeJS/SwiftUI style:
		-- duration determines 'hardness' or 'speed'
		-- bounce determines 'bounciness'
		-- Simple mapping for теперь:
		-- damping_ratio = 1 - bounce
		-- If bounce > 0, we want underdamped (zeta < 1)
		-- If bounce < 0, we want overdamped (zeta > 1)
		local zeta

		if bounce >= 0 then
			zeta = 1 - bounce -- bounce 1 -> zeta 0, bounce 0 -> zeta 1
		else
			zeta = 1 / (1 + bounce) -- bounce -0.5 -> zeta 2?
			if zeta < 1 then zeta = 1 - bounce end -- fallback
		end

		-- duration influence on w0
		-- T = 2*pi / (w0 * sqrt(1-zeta^2))
		-- Let's say w0 = 2*pi / duration
		w0 = (2 * math.pi) / duration
		m = 1
		k = m * w0 * w0
		c = 2 * zeta * math.sqrt(m * k)
	end

	local epsilon = config.settle == false and 0.5 or config.epsilon
	local duration = calculate_settling_duration(m, k, c, v0, epsilon)
	local solver, velocity_solver = solve_spring(m, k, c, v0)
	-- We need to normalize the solver to [0, 1] relative to settling duration
	-- because goluwa's animation system uses normalized alpha [0, 1]
	return function(alpha, duration_override)
		return solver(alpha * (duration_override or duration))
	end,
	duration,
	function(alpha, duration_override)
		return velocity_solver(alpha * (duration_override or duration))
	end
end

return spring

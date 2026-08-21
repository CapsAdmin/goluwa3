-- Shared time-of-impact primitives: coarse sampling over a sweep interval
-- followed by bisection refinement. Evaluate functions report a hit by
-- returning a truthy result; they are called as evaluate(t) or, when an
-- evaluate_context is given, evaluate(evaluate_context, t) so callers do not
-- allocate closures in hot loops.
local toi = {}

local function call_evaluate(evaluate, evaluate_context, t)
	if evaluate_context ~= nil then return evaluate(evaluate_context, t) end

	return evaluate(t)
end

function toi.RefineHit(evaluate, evaluate_context, low, high, refine_steps)
	for _ = 1, refine_steps do
		local mid = (low + high) * 0.5
		local hit = call_evaluate(evaluate, evaluate_context, mid)

		if hit then high = mid else low = mid end
	end

	return high
end

-- Coarse-samples [0, max_fraction] and bisects the first interval that hits.
-- Returns hit_t, hit, or nil.
function toi.FindSampledHit(evaluate, evaluate_context, max_fraction, sample_steps, refine_steps)
	refine_steps = refine_steps or 12
	local start_hit = call_evaluate(evaluate, evaluate_context, 0)

	if start_hit then return 0, start_hit end

	local low = 0
	local high = nil
	local best = nil
	sample_steps = math.max(1, sample_steps or 1)

	for i = 1, sample_steps do
		local t = max_fraction * (i / sample_steps)
		local hit = call_evaluate(evaluate, evaluate_context, t)

		if hit then
			high = t
			best = hit

			break
		end

		low = t
	end

	if not best then return nil end

	for _ = 1, refine_steps do
		local mid = (low + high) * 0.5
		local mid_hit = call_evaluate(evaluate, evaluate_context, mid)

		if mid_hit then
			best = mid_hit
			high = mid
		else
			low = mid
		end
	end

	return high, best
end

return toi

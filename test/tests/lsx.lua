-- Example 4: useRef and useCallback
-- Shows mutable refs and memoized callbacks
local L = require("lsx")
local div, h2, p, button, input, span, canvas = L.div, L.h2, L.p, L.button, L.input, L.span, L.el("canvas")
local component, useState, useEffect, useCallback, useRef, useMemo = L.component, L.useState, L.useEffect, L.useCallback, L.useRef, L.useMemo
-- ============================================
-- useRef for DOM access
-- ============================================
local FocusInput = component(function()
	local inputRef = useRef(nil)
	local handleClick = function()
		if inputRef.current then inputRef.current:focus() end
	end
	return div(
		{
			class = "focus-demo",
			h2({"Focus Demo"}),
			input(
				{
					ref = inputRef,
					type = "text",
					placeholder = "Click the button to focus me",
				}
			),
			button({onClick = handleClick, "Focus Input"}),
		}
	)
end)
-- ============================================
-- useRef for mutable values (no re-render)
-- ============================================
local StopWatch = component(function()
	local time, setTime = useState(0)
	local isRunning, setIsRunning = useState(false)
	local intervalRef = useRef(nil)

	useEffect(
		function()
			if isRunning then
				intervalRef.current = "interval_id" -- setInterval equivalent
				print("Started interval")
			else
				if intervalRef.current then
					print("Cleared interval:", intervalRef.current)
					intervalRef.current = nil
				end
			end

			return function()
				if intervalRef.current then
					print("Cleanup: clearing interval")
					intervalRef.current = nil
				end
			end
		end,
		{isRunning}
	)

	local format = function(ms)
		local mins = math.floor(ms / 60000)
		local secs = math.floor((ms % 60000) / 1000)
		local centis = math.floor((ms % 1000) / 10)
		return string.format("%02d:%02d.%02d", mins, secs, centis)
	end
	return div(
		{
			class = "stopwatch",
			h2({"Stopwatch"}),
			p({class = "time", format(time)}),
			button(
				{
					onClick = function()
						setIsRunning(not isRunning)
					end,
					isRunning and
					"Stop" or
					"Start",
				}
			),
			button(
				{
					onClick = function()
						setIsRunning(false)
						setTime(0)
					end,
					"Reset",
				}
			),
		}
	)
end)

-- ============================================
-- useRef to track previous value
-- ============================================
local function usePrevious(value)
	local ref = useRef(nil)

	useEffect(function()
		ref.current = value
	end, {value})

	return ref.current
end

local CounterWithPrevious = component(function()
	local count, setCount = useState(0)
	local prevCount = usePrevious(count)
	return div(
		{
			class = "counter-prev",
			h2({"Counter with Previous"}),
			p({"Current: ", count}),
			p({"Previous: ", prevCount or "none"}),
			p(
				{
					prevCount and
					count > prevCount and
					"↑ Increased" or
					prevCount and
					count < prevCount and
					"↓ Decreased" or
					"No change",
				}
			),
			button({
				onClick = function()
					setCount(count - 1)
				end,
				"-",
			}),
			button({
				onClick = function()
					setCount(count + 1)
				end,
				"+",
			}),
		}
	)
end)
-- ============================================
-- useCallback to prevent unnecessary re-renders
-- ============================================
local ExpensiveChild = component(function(props)
	print("ExpensiveChild rendered")
	return div(
		{
			class = "expensive",
			p({"Value: ", props.value}),
			button({onClick = props.onClick, "Click"}),
		}
	)
end)
local ParentWithCallback = component(function()
	local count, setCount = useState(0)
	local other, setOther = useState(0)
	-- Without useCallback, this creates a new function every render
	-- causing ExpensiveChild to re-render unnecessarily
	local handleClick = useCallback(function()
		setCount(function(c)
			return c + 1
		end)
	end, {}) -- Empty deps = never changes
	return div(
		{
			class = "parent",
			h2({"useCallback Demo"}),
			p({"Other state (changing this shouldn't re-render child): ", other}),
			button(
				{
					onClick = function()
						setOther(other + 1)
					end,
					"Change Other",
				}
			),
			ExpensiveChild({value = count, onClick = handleClick}),
		}
	)
end)
-- ============================================
-- Canvas drawing with ref
-- ============================================
local DrawingCanvas = component(function()
	local canvasRef = useRef(nil)
	local isDrawing = useRef(false)
	local lastPos = useRef({x = 0, y = 0})
	local color, setColor = useState("#000000")
	local brushSize, setBrushSize = useState(5)
	local startDrawing = useCallback(
		function(e)
			isDrawing.current = true
			lastPos.current = {x = e.offsetX, y = e.offsetY}
		end,
		{}
	)
	local stopDrawing = useCallback(function()
		isDrawing.current = false
	end, {})
	local draw = useCallback(
		function(e)
			if not isDrawing.current then return end

			local ctx = canvasRef.current and canvasRef.current:getContext("2d")

			if not ctx then return end

			ctx.strokeStyle = color
			ctx.lineWidth = brushSize
			ctx.lineCap = "round"
			ctx:beginPath()
			ctx:moveTo(lastPos.current.x, lastPos.current.y)
			ctx:lineTo(e.offsetX, e.offsetY)
			ctx:stroke()
			lastPos.current = {x = e.offsetX, y = e.offsetY}
		end,
		{color, brushSize}
	)
	local clear = function()
		local ctx = canvasRef.current and canvasRef.current:getContext("2d")

		if ctx then ctx:clearRect(0, 0, 400, 300) end
	end
	return div(
		{
			class = "drawing-app",
			h2({"Drawing Canvas"}),
			div(
				{
					class = "controls",
					input(
						{
							type = "color",
							value = color,
							onChange = function(e)
								setColor(e.target.value)
							end,
						}
					),
					input(
						{
							type = "range",
							min = "1",
							max = "20",
							value = brushSize,
							onChange = function(e)
								setBrushSize(tonumber(e.target.value))
							end,
						}
					),
					span({"Size: ", brushSize}),
					button({onClick = clear, "Clear"}),
				}
			),
			canvas(
				{
					ref = canvasRef,
					width = "400",
					height = "300",
					class = "canvas",
					onMouseDown = startDrawing,
					onMouseUp = stopDrawing,
					onMouseOut = stopDrawing,
					onMouseMove = draw,
				}
			),
		}
	)
end)
-- ============================================
-- Render all examples
-- ============================================
local App = component(function()
	return div(
		{
			class = "app",
			h2({"useRef & useCallback Examples"}),
			FocusInput({}),
			StopWatch({}),
			CounterWithPrevious({}),
			ParentWithCallback({}),
			DrawingCanvas({}),
		}
	)
end)
print(L.render(App({})))

local terminal_module = require("terminal")
local term = terminal_module.WrapFile(io.stdin, io.stdout)

-- Helper function to pause between sections
local function pause()
	io.stderr:write("Press any key to continue...")
	io.stderr:flush()
	while true do
		local event = term:ReadEvent()
		if event and event.key then
			break
		end
	end
	io.stderr:write("\n")
end

-- Clear screen and setup
term:Clear()
term:EnableCaret(false)

-- Title
term:SetCaretPosition(1, 1)
term:PushBold()
term:PushForegroundColor(255, 255, 255)
term:Write("Terminal.lua Feature Showcase")
term:PopAttribute()
term:PopAttribute()
term:Write("\n\n")

-- Terminal info
local width, height = term:GetSize()
term:Write(string.format("Terminal size: %dx%d\n", width, height))
term:Write(string.format("Platform: %s\n\n", jit.os))

-- Font capability test
term:Write("Font capability test (if you see boxes/question marks, your font lacks support):\n")
term:Write("  Box drawing: ┌─┐│└┘ ├┤┬┴┼\n")
term:Write("  Block chars: █ ▓ ▒ ░\n")
term:Write("  Emojis: 😀 🚀 (may not render depending on terminal)\n\n")

pause()

-- Section 1: Basic Colors (RGB)
term:PushBold()
term:Write("=== True Color RGB Support ===\n")
term:PopAttribute()

term:Write("Primary colors:\n")
term:PushForegroundColor(255, 0, 0)
term:Write("  Red (255,0,0)")
term:PopAttribute()
term:Write("\n")
term:PushForegroundColor(0, 255, 0)
term:Write("  Green (0,255,0)")
term:PopAttribute()
term:Write("\n")
term:PushForegroundColor(0, 0, 255)
term:Write("  Blue (0,0,255)")
term:PopAttribute()
term:Write("\n\n")

term:Write("Secondary colors:\n")
term:PushForegroundColor(255, 255, 0)
term:Write("  Yellow (255,255,0)")
term:PopAttribute()
term:Write("\n")
term:PushForegroundColor(0, 255, 255)
term:Write("  Cyan (0,255,255)")
term:PopAttribute()
term:Write("\n")
term:PushForegroundColor(255, 0, 255)
term:Write("  Magenta (255,0,255)")
term:PopAttribute()
term:Write("\n\n")

-- Color gradient
term:Write("Color gradient (256 steps):\n  ")
for i = 0, 255 do
	local r = i
	local g = 255 - i
	local b = 128
	term:PushForegroundColor(r, g, b)
	term:Write("█")
	term:PopAttribute()
end
term:Write("\n\n")

pause()

-- Section 2: Background Colors
term:Clear()
term:SetCaretPosition(1, 1)
term:PushBold()
term:Write("=== Background Colors ===\n")
term:PopAttribute()

term:Write("Text with colored backgrounds:\n")
term:PushBackgroundColor(128, 0, 0)
term:Write(" Dark Red Background ")
term:PopAttribute()
term:Write("\n")
term:PushBackgroundColor(0, 128, 0)
term:Write(" Dark Green Background ")
term:PopAttribute()
term:Write("\n")
term:PushBackgroundColor(0, 0, 128)
term:Write(" Dark Blue Background ")
term:PopAttribute()
term:Write("\n\n")

term:Write("Combined foreground and background:\n")
term:PushForegroundColor(255, 255, 0)
term:PushBackgroundColor(128, 0, 128)
term:Write(" Yellow on Purple ")
term:PopAttribute()
term:PopAttribute()
term:Write("\n")
term:PushForegroundColor(0, 255, 0)
term:PushBackgroundColor(0, 0, 0)
term:Write(" Green on Black ")
term:PopAttribute()
term:PopAttribute()
term:Write("\n\n")

pause()

-- Section 3: Text Attributes
term:Clear()
term:SetCaretPosition(1, 1)
term:PushBold()
term:Write("=== Text Attributes ===\n")
term:PopAttribute()

term:Write("Normal text\n")

term:PushBold()
term:Write("Bold text\n")
term:PopAttribute()

term:PushDim()
term:Write("Dim text\n")
term:PopAttribute()

term:PushItalic()
term:Write("Italic text\n")
term:PopAttribute()

term:PushUnderline()
term:Write("Underlined text\n")
term:PopAttribute()

term:Write("\nCombined attributes:\n")
term:PushBold()
term:PushItalic()
term:PushUnderline()
term:PushForegroundColor(255, 100, 0)
term:Write("Bold + Italic + Underline + Orange\n")
term:PopAttribute()
term:PopAttribute()
term:PopAttribute()
term:PopAttribute()

term:Write("\n")
pause()

-- Section 4: Unicode Support
term:Clear()
term:SetCaretPosition(1, 1)
term:PushBold()
term:Write("=== Unicode Support ===\n")
term:PopAttribute()

term:Write("\nEmojis:\n")
term:Write("  😀 😎 🎉 🚀 ⭐ 🌈 🔥 💻 🎨 🎵\n\n")

term:Write("Box drawing characters:\n")
term:Write("  ┌─────────────────┐\n")
term:Write("  │ Box Drawing     │\n")
term:Write("  ├─────────────────┤\n")
term:Write("  │ Unicode Rocks!  │\n")
term:Write("  └─────────────────┘\n\n")

term:Write("Block elements:\n")
term:Write("  ░░░░ ▒▒▒▒ ▓▓▓▓ ████\n\n")

term:Write("Mathematical symbols:\n")
term:Write("  ∀ ∃ ∈ ∉ ∋ ∑ ∏ ∫ √ ∞ ≈ ≠ ≤ ≥\n\n")

term:Write("Arrow characters:\n")
term:Write("  ← → ↑ ↓ ↔ ↕ ⇐ ⇒ ⇑ ⇓ ⇔ ⇕\n\n")

term:Write("Greek letters:\n")
term:Write("  α β γ δ ε ζ η θ ι κ λ μ ν ξ ο π ρ σ τ υ φ χ ψ ω\n")
term:Write("  Α Β Γ Δ Ε Ζ Η Θ Ι Κ Λ Μ Ν Ξ Ο Π Ρ Σ Τ Υ Φ Χ Ψ Ω\n\n")

term:Write("International characters:\n")
term:Write("  English: Hello World!\n")
term:Write("  Japanese: こんにちは世界\n")
term:Write("  Korean: 안녕하세요 세계\n")
term:Write("  Chinese: 你好世界\n")
term:Write("  Arabic: مرحبا بالعالم\n")
term:Write("  Russian: Привет мир\n")
term:Write("  Hebrew: שלום עולם\n\n")

term:Write("Braille patterns:\n")
term:Write("  ⠁⠂⠃⠄⠅⠆⠇⠈⠉⠊⠋⠌⠍⠎⠏⠐⠑⠒⠓⠔⠕⠖⠗⠘⠙⠚⠛⠜⠝⠞⠟\n\n")

pause()

-- Section 5: Complex Demonstration - Rainbow Text
term:Clear()
term:SetCaretPosition(1, 1)
term:PushBold()
term:Write("=== Rainbow Text Demo ===\n\n")
term:PopAttribute()

local text = "The quick brown fox jumps over the lazy dog 🦊🐶"
local colors = {
	{255, 0, 0},     -- Red
	{255, 127, 0},   -- Orange
	{255, 255, 0},   -- Yellow
	{0, 255, 0},     -- Green
	{0, 0, 255},     -- Blue
	{75, 0, 130},    -- Indigo
	{148, 0, 211},   -- Violet
}

-- Character by character rainbow
for i = 1, #text do
	local char = text:sub(i, i)
	local color_index = ((i - 1) % #colors) + 1
	local color = colors[color_index]
	term:PushForegroundColor(color[1], color[2], color[3])
	term:Write(char)
	term:PopAttribute()
end
term:Write("\n\n")

-- Bold rainbow
term:PushBold()
for i = 1, #text do
	local char = text:sub(i, i)
	local color_index = ((i - 1) % #colors) + 1
	local color = colors[color_index]
	term:PushForegroundColor(color[1], color[2], color[3])
	term:Write(char)
	term:PopAttribute()
end
term:PopAttribute()
term:Write("\n\n")

pause()

-- Section 6: Attribute Stack Demo
term:Clear()
term:SetCaretPosition(1, 1)
term:PushBold()
term:Write("=== Attribute Stack Demo ===\n\n")
term:PopAttribute()

term:Write("Demonstrating nested attributes:\n\n")
term:Write("Level 0: Normal text\n")
term:PushForegroundColor(255, 0, 0)
term:Write("  Level 1: Red text\n")
term:PushBold()
term:Write("    Level 2: Red + Bold\n")
term:PushUnderline()
term:Write("      Level 3: Red + Bold + Underline\n")
term:PushItalic()
term:Write("        Level 4: Red + Bold + Underline + Italic\n")
term:PopAttribute() -- Remove italic
term:Write("      Back to Level 3\n")
term:PopAttribute() -- Remove underline
term:Write("    Back to Level 2\n")
term:PopAttribute() -- Remove bold
term:Write("  Back to Level 1\n")
term:PopAttribute() -- Remove red
term:Write("Back to Level 0\n\n")

pause()

-- Section 7: Color Palette
term:Clear()
term:SetCaretPosition(1, 1)
term:PushBold()
term:Write("=== 24-bit Color Palette ===\n\n")
term:PopAttribute()

term:Write("Grayscale gradient:\n")
for i = 0, 255, 4 do
	term:PushBackgroundColor(i, i, i)
	term:Write("  ")
	term:PopAttribute()
end
term:Write("\n\n")

term:Write("Red gradient:\n")
for i = 0, 255, 4 do
	term:PushBackgroundColor(i, 0, 0)
	term:Write("  ")
	term:PopAttribute()
end
term:Write("\n\n")

term:Write("Green gradient:\n")
for i = 0, 255, 4 do
	term:PushBackgroundColor(0, i, 0)
	term:Write("  ")
	term:PopAttribute()
end
term:Write("\n\n")

term:Write("Blue gradient:\n")
for i = 0, 255, 4 do
	term:PushBackgroundColor(0, 0, i)
	term:Write("  ")
	term:PopAttribute()
end
term:Write("\n\n")

term:Write("Hue spectrum:\n")
for i = 0, 359, 6 do
	local h = i / 360
	local s = 1
	local v = 1

	-- HSV to RGB conversion
	local c = v * s
	local x = c * (1 - math.abs((h * 6) % 2 - 1))
	local m = v - c

	local r, g, b
	if h < 1/6 then
		r, g, b = c, x, 0
	elseif h < 2/6 then
		r, g, b = x, c, 0
	elseif h < 3/6 then
		r, g, b = 0, c, x
	elseif h < 4/6 then
		r, g, b = 0, x, c
	elseif h < 5/6 then
		r, g, b = x, 0, c
	else
		r, g, b = c, 0, x
	end

	r = math.floor((r + m) * 255)
	g = math.floor((g + m) * 255)
	b = math.floor((b + m) * 255)

	term:PushBackgroundColor(r, g, b)
	term:Write(" ")
	term:PopAttribute()
end
term:Write("\n\n")

pause()

-- Final section: Creative Design
term:Clear()
term:SetCaretPosition(1, 1)

-- Create a colorful banner (ASCII-safe version)
local banner = {
	"  ########  #######  #######  ###     ### #### ###     ##    ###    ##       ",
	"     ##     ##       ##   ##  ####   #### ####  ####   ##   ## ##   ##       ",
	"     ##     #####    #######  ## ## ## ## ####  ## ##  ##  ##   ##  ##       ",
	"     ##     ##       ##   ##  ##  ###  ## ####  ##  ## ##  #######  ##       ",
	"     ##     #######  ##   ##  ##       ## ####  ##   #### ##     ## ######## ",
}

for row = 1, #banner do
	for col = 1, #banner[row] do
		local char = banner[row]:sub(col, col)
		-- Create a position-based color gradient
		local r = math.floor((col / #banner[row]) * 255)
		local g = math.floor((row / #banner) * 255)
		local b = 128
		term:PushForegroundColor(r, g, b)
		term:Write(char)
		term:PopAttribute()
	end
	term:Write("\n")
end

term:Write("\n")
term:PushBold()
term:PushForegroundColor(0, 255, 255)
term:Write("✨ Full RGB color support with Unicode! ✨\n")
term:PopAttribute()
term:PopAttribute()

term:Write("\n")
term:PushForegroundColor(150, 150, 150)
term:Write("Press any key to exit...")
term:PopAttribute()
term:Flush()

-- Wait for final keypress
while true do
	local event = term:ReadEvent()
	if event and event.key then
		break
	end
end

-- Cleanup
term:Clear()
term:EnableCaret(true)
term:SetCaretPosition(1, 1)

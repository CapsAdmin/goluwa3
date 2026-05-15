local T = import("test/environment.lua")
local jinja2 = import("goluwa/llamacpp/jinja2.lua")
local BIG_TEST = [==[
{%- set image_count = namespace(value=0) %}
{%- set video_count = namespace(value=0) %}
{%- macro render_content(content, do_vision_count, is_system_content=false) %}
    {%- if content is string %}
        {{- content }}
    {%- elif content is iterable and content is not mapping %}
        {%- for item in content %}
            {%- if 'image' in item or 'image_url' in item or item.type == 'image' %}
                {%- if is_system_content %}
                    {{- raise_exception('System message cannot contain images.') }}
                {%- endif %}
                {%- if do_vision_count %}
                    {%- set image_count.value = image_count.value + 1 %}
                {%- endif %}
                {%- if add_vision_id %}
                    {{- 'Picture ' ~ image_count.value ~ ': ' }}
                {%- endif %}
                {{- '<|vision_start|><|image_pad|><|vision_end|>' }}
            {%- elif 'video' in item or item.type == 'video' %}
                {%- if is_system_content %}
                    {{- raise_exception('System message cannot contain videos.') }}
                {%- endif %}
                {%- if do_vision_count %}
                    {%- set video_count.value = video_count.value + 1 %}
                {%- endif %}
                {%- if add_vision_id %}
                    {{- 'Video ' ~ video_count.value ~ ': ' }}
                {%- endif %}
                {{- '<|vision_start|><|video_pad|><|vision_end|>' }}
            {%- elif 'text' in item %}
                {{- item.text }}
            {%- else %}
                {{- raise_exception('Unexpected item type in content.') }}
            {%- endif %}
        {%- endfor %}
    {%- elif content is none or content is undefined %}
        {{- '' }}
    {%- else %}
        {{- raise_exception('Unexpected content type.') }}
    {%- endif %}
{%- endmacro %}
{%- if not messages %}
    {{- raise_exception('No messages provided.') }}
{%- endif %}
{%- if tools and tools is iterable and tools is not mapping %}
    {{- '<|im_start|>system\n' }}
    {{- "# Tools\n\nYou have access to the following functions:\n\n<tools>" }}
    {%- for tool in tools %}
        {{- "\n" }}
        {{- tool | tojson }}
    {%- endfor %}
    {{- "\n</tools>" }}
    {{- '\n\nIf you choose to call a function ONLY reply in the following format with NO suffix:\n\n<tool_call>\n<function=example_function_name>\n<parameter=example_parameter_1>\nvalue_1\n</parameter>\n<parameter=example_parameter_2>\nThis is the value for the second parameter\nthat can span\nmultiple lines\n</parameter>\n</function>\n</tool_call>\n\n<IMPORTANT>\nReminder:\n- Function calls MUST follow the specified format: an inner <function=...></function> block must be nested within <tool_call></tool_call> XML tags\n- Required parameters MUST be specified\n- You may provide optional reasoning for your function call in natural language BEFORE the function call, but NOT after\n- If there is no function call available, answer the question like normal with your current knowledge and do not tell the user about function calls\n</IMPORTANT>' }}
    {%- if messages[0].role == 'system' %}
        {%- set content = render_content(messages[0].content, false, true)|trim %}
        {%- if content %}
            {{- '\n\n' + content }}
        {%- endif %}
    {%- endif %}
    {{- '<|im_end|>\n' }}
{%- else %}
    {%- if messages[0].role == 'system' %}
        {%- set content = render_content(messages[0].content, false, true)|trim %}
        {{- '<|im_start|>system\n' + content + '<|im_end|>\n' }}
    {%- endif %}
{%- endif %}
{%- set ns = namespace(multi_step_tool=true, last_query_index=messages|length - 1) %}
{%- for message in messages[::-1] %}
    {%- set index = (messages|length - 1) - loop.index0 %}
    {%- if ns.multi_step_tool and message.role == "user" %}
        {%- set content = render_content(message.content, false)|trim %}
        {%- if not(content.startswith('<tool_response>') and content.endswith('</tool_response>')) %}
            {%- set ns.multi_step_tool = false %}
            {%- set ns.last_query_index = index %}
        {%- endif %}
    {%- endif %}
{%- endfor %}
{%- if ns.multi_step_tool %}
    {{- raise_exception('No user query found in messages.') }}
{%- endif %}
{%- for message in messages %}
    {%- set content = render_content(message.content, true)|trim %}
    {%- if message.role == "system" %}
        {%- if not loop.first %}
            {{- raise_exception('System message must be at the beginning.') }}
        {%- endif %}
    {%- elif message.role == "user" %}
        {{- '<|im_start|>' + message.role + '\n' + content + '<|im_end|>' + '\n' }}
    {%- elif message.role == "assistant" %}
        {%- set reasoning_content = '' %}
        {%- if message.reasoning_content is string %}
            {%- set reasoning_content = message.reasoning_content %}
        {%- else %}
            {%- if '</think>' in content %}
                {%- set reasoning_content = content.split('</think>')[0].rstrip('\n').split('<think>')[-1].lstrip('\n') %}
                {%- set content = content.split('</think>')[-1].lstrip('\n') %}
            {%- endif %}
        {%- endif %}
        {%- set reasoning_content = reasoning_content|trim %}
        {%- if loop.index0 > ns.last_query_index %}
            {{- '<|im_start|>' + message.role + '\n<think>\n' + reasoning_content + '\n</think>\n\n' + content }}
        {%- else %}
            {{- '<|im_start|>' + message.role + '\n' + content }}
        {%- endif %}
        {%- if message.tool_calls and message.tool_calls is iterable and message.tool_calls is not mapping %}
            {%- for tool_call in message.tool_calls %}
                {%- if tool_call.function is defined %}
                    {%- set tool_call = tool_call.function %}
                {%- endif %}
                {%- if loop.first %}
                    {%- if content|trim %}
                        {{- '\n\n<tool_call>\n<function=' + tool_call.name + '>\n' }}
                    {%- else %}
                        {{- '<tool_call>\n<function=' + tool_call.name + '>\n' }}
                    {%- endif %}
                {%- else %}
                    {{- '\n<tool_call>\n<function=' + tool_call.name + '>\n' }}
                {%- endif %}
                {%- if tool_call.arguments is mapping %}
                    {%- for args_name in tool_call.arguments %}
                        {%- set args_value = tool_call.arguments[args_name] %}
                        {{- '<parameter=' + args_name + '>\n' }}
                        {%- set args_value = args_value | tojson | safe if args_value is mapping or (args_value is sequence and args_value is not string) else args_value | string %}
                        {{- args_value }}
                        {{- '\n</parameter>\n' }}
                    {%- endfor %}
                {%- endif %}
                {{- '</function>\n</tool_call>' }}
            {%- endfor %}
        {%- endif %}
        {{- '<|im_end|>\n' }}
    {%- elif message.role == "tool" %}
        {%- if loop.previtem and loop.previtem.role != "tool" %}
            {{- '<|im_start|>user' }}
        {%- endif %}
        {{- '\n<tool_response>\n' }}
        {{- content }}
        {{- '\n</tool_response>' }}
        {%- if not loop.last and loop.nextitem.role != "tool" %}
            {{- '<|im_end|>\n' }}
        {%- elif loop.last %}
            {{- '<|im_end|>\n' }}
        {%- endif %}
    {%- else %}
        {{- raise_exception('Unexpected message role.') }}
    {%- endif %}
{%- endfor %}
{%- if add_generation_prompt %}
    {{- '<|im_start|>assistant\n' }}
    {%- if enable_thinking is defined and enable_thinking is false %}
        {{- '<think>\n\n</think>\n\n' }}
    {%- else %}
        {{- '<think>\n' }}
    {%- endif %}
{%- endif %}
]==]

T.Test("basic statement", function()
	local tokens = jinja2.tokenize("{% set x = 1 %}")
	T(#tokens)["=="](1)
	T(tokens[1].type)["=="]("statement")
	T(tokens[1].value)["=="](" set x = 1 ")
end)

T.Test("text and statement", function()
	local tokens = jinja2.tokenize("hello {% if true %}")
	T(#tokens)["=="](2)
	T(tokens[1].type)["=="]("text")
	T(tokens[1].value)["=="]("hello ")
	T(tokens[2].type)["=="]("statement")
	T(tokens[2].value)["=="](" if true ")
end)

T.Test("{%- strips preceding whitespace", function()
	local tokens = jinja2.tokenize("hello  {%- if true %}")
	T(#tokens)["=="](2)
	T(tokens[1].type)["=="]("text")
	T(tokens[1].value)["=="]("hello")
	T(tokens[2].value)["=="](" if true ")
end)

T.Test("-%} strips following whitespace", function()
	local tokens = jinja2.tokenize("{% if true -%}  world")
	T(#tokens)["=="](2)
	T(tokens[1].type)["=="]("statement")
	T(tokens[1].value)["=="](" if true ")
	T(tokens[2].type)["=="]("text")
	T(tokens[2].value)["=="]("world")
end)

T.Test("{%- and -%} both strip", function()
	local tokens = jinja2.tokenize("hello  {%- code -%}  world")
	T(#tokens)["=="](3)
	T(tokens[1].value)["=="]("hello")
	T(tokens[2].type)["=="]("statement")
	T(tokens[2].value)["=="](" code ")
	T(tokens[3].value)["=="]("world")
end)

T.Test("basic expression", function()
	local tokens = jinja2.tokenize("{{ name }}")
	T(#tokens)["=="](1)
	T(tokens[1].type)["=="]("expression")
	T(tokens[1].value)["=="](" name ")
end)

T.Test("{{- strips preceding whitespace", function()
	local tokens = jinja2.tokenize("hello  {{- content }}")
	T(#tokens)["=="](2)
	T(tokens[1].value)["=="]("hello")
	T(tokens[2].type)["=="]("expression")
	T(tokens[2].value)["=="](" content ")
end)

T.Test("-}} strips following whitespace", function()
	local tokens = jinja2.tokenize("{{ content -}}  world")
	T(#tokens)["=="](2)
	T(tokens[1].type)["=="]("expression")
	T(tokens[1].value)["=="](" content ")
	T(tokens[2].type)["=="]("text")
	T(tokens[2].value)["=="]("world")
end)

T.Test("comment is stripped", function()
	local tokens = jinja2.tokenize("hello{# this is a comment #}world")
	T(#tokens)["=="](2)
	T(tokens[1].type)["=="]("text")
	T(tokens[1].value)["=="]("hello")
	T(tokens[2].type)["=="]("text")
	T(tokens[2].value)["=="]("world")
end)

T.Test("multiline with {%-", function()
	local tokens = jinja2.tokenize("{%- if true %}\nhello\n{%- endif %}")
	T(#tokens)["=="](3)
	T(tokens[1].type)["=="]("statement")
	T(tokens[1].value)["=="](" if true ")
	T(tokens[2].type)["=="]("text")
	T(tokens[2].value)["=="]("\nhello")
	T(tokens[3].type)["=="]("statement")
	T(tokens[3].value)["=="](" endif ")
end)

T.Test("mixed statements and expressions", function()
	local tokens = jinja2.tokenize("{% if x %}{{ y }}{% endif %}")
	T(#tokens)["=="](3)
	T(tokens[1].type)["=="]("statement")
	T(tokens[1].value)["=="](" if x ")
	T(tokens[2].type)["=="]("expression")
	T(tokens[2].value)["=="](" y ")
	T(tokens[3].type)["=="]("statement")
	T(tokens[3].value)["=="](" endif ")
end)

T.Test("BIG_TEST tokenizes", function()
	local tokens = jinja2.tokenize(BIG_TEST)
	T(#tokens > 0)["=="](true)

	for _, tok in ipairs(tokens) do
		T(tok.type == "text" or tok.type == "statement" or tok.type == "expression")["=="](true)
	end
end)

T.Test("BIG_TEST text has no delimiters", function()
	local tokens = jinja2.tokenize(BIG_TEST)

	for _, tok in ipairs(tokens) do
		if tok.type == "text" then
			T(tok.value:find("{%%", 1, true) == nil)["=="](true)
			T(tok.value:find("%%}", 1, true) == nil)["=="](true)
			T(tok.value:find("{{", 1, true) == nil)["=="](true)
			T(tok.value:find("}}", 1, true) == nil)["=="](true)
		end
	end
end)

-- ===== Render tests =====
T.Test("render: text only", function()
	T(jinja2.render("hello world", {}))["=="]("hello world")
end)

T.Test("render: expression", function()
	T(jinja2.render("hello {{ name }}", {name = "world"}))["=="]("hello world")
end)

T.Test("render: if true", function()
	T(jinja2.render("{% if show %}yes{% endif %}", {show = true}))["=="]("yes")
end)

T.Test("render: if false", function()
	T(jinja2.render("{% if show %}yes{% endif %}", {show = false}))["=="]("")
end)

T.Test("render: if/else", function()
	T(jinja2.render("{% if x %}a{% else %}b{% endif %}", {x = false}))["=="]("b")
end)

T.Test("render: if/elif/else", function()
	local tmpl = "{% if x == 1 %}one{% elif x == 2 %}two{% else %}other{% endif %}"
	T(jinja2.render(tmpl, {x = 2}))["=="]("two")
end)

T.Test("render: for loop", function()
	T(jinja2.render("{% for x in items %}{{ x }}{% endfor %}", {items = {"a", "b", "c"}}))["=="]("abc")
end)

T.Test("render: for loop.index0", function()
	T(
		jinja2.render("{% for x in items %}{{ loop.index0 }}{% endfor %}", {items = {"a", "b"}})
	)["=="]("01")
end)

T.Test("render: for loop.first/last", function()
	local tmpl = "{% for x in items %}{% if loop.first %}F{% endif %}{{ x }}{% if loop.last %}L{% endif %}{% endfor %}"
	T(jinja2.render(tmpl, {items = {"a", "b", "c"}}))["=="]("FabcL")
end)

T.Test("render: string concat ~", function()
	T(jinja2.render("{{ 'a' ~ 'b' ~ 'c' }}", {}))["=="]("abc")
end)

T.Test("render: string concat +", function()
	T(jinja2.render("{{ 'hello' + ' ' + 'world' }}", {}))["=="]("hello world")
end)

T.Test("render: filter trim", function()
	T(jinja2.render("{{ x|trim }}", {x = "  hello  "}))["=="]("hello")
end)

T.Test("render: filter length", function()
	T(jinja2.render("{{ items|length }}", {items = {1, 2, 3}}))["=="]("3")
end)

T.Test("render: filter tojson", function()
	local result = jinja2.render("{{ x | tojson }}", {x = {a = 1}})
	T(result:find("\"a\"") ~= nil)["=="](true)
end)

T.Test("render: is string", function()
	T(jinja2.render("{% if x is string %}yes{% endif %}", {x = "hello"}))["=="]("yes")
end)

T.Test("render: is not mapping", function()
	T(jinja2.render("{% if x is not mapping %}array{% else %}map{% endif %}", {x = {1, 2}}))["=="]("array")
end)

T.Test("render: is mapping", function()
	T(jinja2.render("{% if x is mapping %}map{% else %}other{% endif %}", {x = {a = 1}}))["=="]("map")
end)

T.Test("render: in operator (table key)", function()
	T(jinja2.render("{% if 'a' in x %}yes{% endif %}", {x = {a = 1}}))["=="]("yes")
end)

T.Test("render: in operator (string)", function()
	T(jinja2.render("{% if 'world' in x %}yes{% endif %}", {x = "hello world"}))["=="]("yes")
end)

T.Test("render: not operator", function()
	T(jinja2.render("{% if not x %}yes{% endif %}", {x = false}))["=="]("yes")
end)

T.Test("render: 0-based indexing", function()
	T(jinja2.render("{{ items[0] }}", {items = {"first", "second"}}))["=="]("first")
end)

T.Test("render: dot access", function()
	T(jinja2.render("{{ obj.name }}", {obj = {name = "test"}}))["=="]("test")
end)

T.Test("render: set variable", function()
	T(jinja2.render("{% set x = 'hello' %}{{ x }}", {}))["=="]("hello")
end)

T.Test("render: namespace", function()
	T(
		jinja2.render(
			"{% set ns = namespace(value=0) %}{% set ns.value = ns.value + 1 %}{{ ns.value }}",
			{}
		)
	)["=="]("1")
end)

T.Test("render: macro", function()
	local tmpl = "{%- macro greet(name) %}hello {{ name }}{%- endmacro %}{{ greet('world') }}"
	T(jinja2.render(tmpl, {}))["=="]("hello world")
end)

T.Test("render: macro with default arg", function()
	local tmpl = "{%- macro greet(name, punct='!') %}{{ name }}{{ punct }}{%- endmacro %}{{ greet('hi') }}"
	T(jinja2.render(tmpl, {}))["=="]("hi!")
end)

T.Test("render: raise_exception", function()
	local ok, err = pcall(jinja2.render, "{{ raise_exception('boom') }}", {})
	T(ok)["=="](false)
	T(tostring(err):find("boom") ~= nil)["=="](true)
end)

T.Test("render: reversed", function()
	local tmpl = "{% for x in items[::-1] %}{{ x }}{% endfor %}"
	T(jinja2.render(tmpl, {items = {"a", "b", "c"}}))["=="]("cba")
end)

T.Test("render: string methods startswith/endswith", function()
	local tmpl = "{% if x.startswith('he') %}yes{% endif %}"
	T(jinja2.render(tmpl, {x = "hello"}))["=="]("yes")
end)

T.Test("render: string split and index", function()
	local tmpl = "{{ x.split('-')[0] }}"
	T(jinja2.render(tmpl, {x = "a-b-c"}))["=="]("a")
end)

T.Test("render: is defined / is undefined", function()
	T(jinja2.render("{% if x is defined %}yes{% else %}no{% endif %}", {x = 1}))["=="]("yes")
	T(jinja2.render("{% if x is defined %}yes{% else %}no{% endif %}", {}))["=="]("no")
end)

T.Test("render: whitespace trimming {%- -%}", function()
	T(jinja2.render("hello  {%- if true -%}  world{%- endif %}", {}))["=="]("helloworld")
end)

T.Test("render: loop.previtem/nextitem", function()
	local tmpl = "{% for x in items %}{% if loop.previtem %}p{{ loop.previtem }}{% endif %}{% endfor %}"
	T(jinja2.render(tmpl, {items = {"a", "b", "c"}}))["=="]("papb")
end)

T.Test("render: ternary expression", function()
	local tmpl = "{{ 'yes' if x else 'no' }}"
	T(jinja2.render(tmpl, {x = true}))["=="]("yes")
	T(jinja2.render(tmpl, {x = false}))["=="]("no")
end)

T.Test("render: filter chain", function()
	local tmpl = "{{ x|trim|length }}"
	T(jinja2.render(tmpl, {x = "  hi  "}))["=="]("2")
end)

T.Test("render: != operator", function()
	T(jinja2.render("{% if x != 'a' %}yes{% endif %}", {x = "b"}))["=="]("yes")
end)

T.Test("render: for over mapping keys", function()
	local tmpl = "{% for k in items %}{{ k }}{% endfor %}"
	-- Note: iteration order not guaranteed for maps, just check it runs
	local result = jinja2.render(tmpl, {items = {x = 1}})
	T(result)["=="]("x")
end)

T.Test("render: BIG_TEST compiles", function()
	local lua_source = jinja2.compile(BIG_TEST)
	T(type(lua_source))["=="]("string")
	T(#lua_source > 0)["=="](true)
	-- verify it's valid Lua
	local fn, err = loadstring(lua_source, "big_test_check")
	T(fn ~= nil)["=="](true)
end)

T.Test("render: BIG_TEST simple messages", function()
	local result = jinja2.render(
		BIG_TEST,
		{
			messages = {
				{role = "system", content = "You are a helpful assistant."},
				{role = "user", content = "Hello!"},
			},
			add_generation_prompt = true,
			enable_thinking = true,
		}
	)
	T(result:find("<|im_start|>system") ~= nil)["=="](true)
	T(result:find("You are a helpful assistant.") ~= nil)["=="](true)
	T(result:find("<|im_start|>user") ~= nil)["=="](true)
	T(result:find("Hello!") ~= nil)["=="](true)
	T(result:find("<|im_start|>assistant") ~= nil)["=="](true)
	T(result:find("<think>") ~= nil)["=="](true)
end)

T.Test("render: BIG_TEST with tools", function()
	local result = jinja2.render(
		BIG_TEST,
		{
			messages = {
				{role = "user", content = "What's the weather?"},
			},
			tools = {
				{
					type = "function",
					["function"] = {name = "get_weather", parameters = {type = "object"}},
				},
			},
			add_generation_prompt = true,
			enable_thinking = true,
		}
	)
	T(result:find("# Tools") ~= nil)["=="](true)
	T(result:find("get_weather") ~= nil)["=="](true)
	T(result:find("<|im_start|>user") ~= nil)["=="](true)
end)

T.Test("render: BIG_TEST assistant response", function()
	local result = jinja2.render(
		BIG_TEST,
		{
			messages = {
				{role = "system", content = "You are helpful."},
				{role = "user", content = "Hi"},
				{role = "assistant", content = "Hello there!"},
			},
			add_generation_prompt = false,
		}
	)
	print(result)
	T(result:find("<|im_start|>assistant") ~= nil)["=="](true)
	T(result:find("Hello there!") ~= nil)["=="](true)
	T(result:find("<|im_end|>") ~= nil)["=="](true)
end)

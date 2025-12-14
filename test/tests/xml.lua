local T = require("test.t")
-- Tests for the XML parser
local xml = require("goluwa.helpers.xml")

T.test("parse simple element", function()
	local doc = xml.parse("<root></root>")
	T(#doc.children)["=="](1)
	T(doc.children[1].tag)["=="]("root")
end)

T.test("parse self-closing element", function()
	local doc = xml.parse("<item/>")
	T(#doc.children)["=="](1)
	T(doc.children[1].tag)["=="]("item")
end)

T.test("parse element with attributes", function()
	local doc = xml.parse("<person name=\"John\" age=\"30\"/>")
	T(#doc.children)["=="](1)
	T(doc.children[1].tag)["=="]("person")
	T(doc.children[1].attrs.name)["=="]("John")
	T(doc.children[1].attrs.age)["=="]("30")
end)

T.test("parse nested elements", function()
	local doc = xml.parse("<parent><child1/><child2/></parent>")
	T(#doc.children)["=="](1)
	T(doc.children[1].tag)["=="]("parent")
	T(#doc.children[1].children)["=="](2)
	T(doc.children[1].children[1].tag)["=="]("child1")
	T(doc.children[1].children[2].tag)["=="]("child2")
end)

T.test("parse deeply nested elements", function()
	local doc = xml.parse("<a><b><c><d/></c></b></a>")
	T(doc.children[1].tag)["=="]("a")
	T(doc.children[1].children[1].tag)["=="]("b")
	T(doc.children[1].children[1].children[1].tag)["=="]("c")
	T(doc.children[1].children[1].children[1].children[1].tag)["=="]("d")
end)

T.test("parse multiple root elements", function()
	local doc = xml.parse("<item1/><item2/><item3/>")
	T(#doc.children)["=="](3)
	T(doc.children[1].tag)["=="]("item1")
	T(doc.children[2].tag)["=="]("item2")
	T(doc.children[3].tag)["=="]("item3")
end)

T.test("comments are removed", function()
	local doc = xml.parse("<root><!-- this is a comment --><child/></root>")
	T(#doc.children)["=="](1)
	T(doc.children[1].tag)["=="]("root")
	T(#doc.children[1].children)["=="](1)
	T(doc.children[1].children[1].tag)["=="]("child")
end)

T.test("ordered attributes are preserved", function()
	local doc = xml.parse("<item z=\"3\" a=\"1\" m=\"2\"/>")
	T(#doc.children[1].orderedattrs)["=="](3)
	T(doc.children[1].orderedattrs[1].name)["=="]("z")
	T(doc.children[1].orderedattrs[1].value)["=="]("3")
	T(doc.children[1].orderedattrs[2].name)["=="]("a")
	T(doc.children[1].orderedattrs[2].value)["=="]("1")
	T(doc.children[1].orderedattrs[3].name)["=="]("m")
	T(doc.children[1].orderedattrs[3].value)["=="]("2")
end)

T.test("attributes with single quotes", function()
	local doc = xml.parse("<item name='value'/>")
	T(doc.children[1].attrs.name)["=="]("value")
end)

T.test("tags with namespaces", function()
	local doc = xml.parse("<ns:element ns:attr='value'/>")
	T(doc.children[1].tag)["=="]("ns:element")
	T(doc.children[1].attrs["ns:attr"])["=="]("value")
end)

T.test("tags with hyphens and underscores", function()
	local doc = xml.parse("<my-element my_attr='test'/>")
	T(doc.children[1].tag)["=="]("my-element")
	T(doc.children[1].attrs.my_attr)["=="]("test")
end)

T.test("empty document", function()
	local doc = xml.parse("")
	T(#doc.children)["=="](0)
end)

T.test("whitespace in content", function()
	local doc = xml.parse("<root>  some text here  </root>")
	T(doc.children[1].tag)["=="]("root")
end)

T.test("wayland-like protocol structure", function()
	local doc = xml.parse([[
<protocol name="test_protocol">
	<interface name="test_interface" version="1">
		<request name="create_surface">
			<arg name="id" type="new_id" interface="test_surface"/>
		</request>
		<event name="configure">
			<arg name="width" type="int"/>
			<arg name="height" type="int"/>
		</event>
		<enum name="error">
			<entry name="invalid" value="0" summary="Invalid operation"/>
		</enum>
	</interface>
</protocol>
]])
	local protocol = doc.children[1]
	T(protocol.tag)["=="]("protocol")
	T(protocol.attrs.name)["=="]("test_protocol")
	local interface = protocol.children[1]
	T(interface.tag)["=="]("interface")
	T(interface.attrs.name)["=="]("test_interface")
	T(interface.attrs.version)["=="]("1")
	local request = interface.children[1]
	T(request.tag)["=="]("request")
	T(request.attrs.name)["=="]("create_surface")
	local request_arg = request.children[1]
	T(request_arg.tag)["=="]("arg")
	T(request_arg.attrs.name)["=="]("id")
	T(request_arg.attrs.type)["=="]("new_id")
	T(request_arg.attrs.interface)["=="]("test_surface")
	local event = interface.children[2]
	T(event.tag)["=="]("event")
	T(event.attrs.name)["=="]("configure")
	local enum = interface.children[3]
	T(enum.tag)["=="]("enum")
	T(enum.attrs.name)["=="]("error")
	local entry = enum.children[1]
	T(entry.tag)["=="]("entry")
	T(entry.attrs.name)["=="]("invalid")
	T(entry.attrs.value)["=="]("0")
end)

T.test("xml declaration", function()
	local doc = xml.parse("<?xml version=\"1.0\"?><root/>")
	T(doc.children[1].tag)["=="]("root")
end)

T.test("doctype declaration", function()
	local doc = xml.parse("<!DOCTYPE html><html/>")
	T(doc.children[1].tag)["=="]("html")
end)

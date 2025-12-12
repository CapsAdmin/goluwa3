-- Tests for the XML parser
local xml = require("goluwa.helpers.xml")

test("parse simple element", function()
	local doc = xml.parse("<root></root>")
	ok(eq(#doc.children, 1), "should have 1 child")
	ok(eq(doc.children[1].tag, "root"), "tag should be 'root'")
end)

test("parse self-closing element", function()
	local doc = xml.parse("<item/>")
	ok(eq(#doc.children, 1), "should have 1 child")
	ok(eq(doc.children[1].tag, "item"), "tag should be 'item'")
end)

test("parse element with attributes", function()
	local doc = xml.parse("<person name=\"John\" age=\"30\"/>")
	ok(eq(#doc.children, 1), "should have 1 child")
	ok(eq(doc.children[1].tag, "person"), "tag should be 'person'")
	ok(eq(doc.children[1].attrs.name, "John"), "name attr should be 'John'")
	ok(eq(doc.children[1].attrs.age, "30"), "age attr should be '30'")
end)

test("parse nested elements", function()
	local doc = xml.parse("<parent><child1/><child2/></parent>")
	ok(eq(#doc.children, 1), "should have 1 root")
	ok(eq(doc.children[1].tag, "parent"), "root tag should be 'parent'")
	ok(eq(#doc.children[1].children, 2), "should have 2 children")
	ok(eq(doc.children[1].children[1].tag, "child1"), "first child should be 'child1'")
	ok(eq(doc.children[1].children[2].tag, "child2"), "second child should be 'child2'")
end)

test("parse deeply nested elements", function()
	local doc = xml.parse("<a><b><c><d/></c></b></a>")
	ok(eq(doc.children[1].tag, "a"), "level 1")
	ok(eq(doc.children[1].children[1].tag, "b"), "level 2")
	ok(eq(doc.children[1].children[1].children[1].tag, "c"), "level 3")
	ok(eq(doc.children[1].children[1].children[1].children[1].tag, "d"), "level 4")
end)

test("parse multiple root elements", function()
	local doc = xml.parse("<item1/><item2/><item3/>")
	ok(eq(#doc.children, 3), "should have 3 roots")
	ok(eq(doc.children[1].tag, "item1"), "first root")
	ok(eq(doc.children[2].tag, "item2"), "second root")
	ok(eq(doc.children[3].tag, "item3"), "third root")
end)

test("comments are removed", function()
	local doc = xml.parse("<root><!-- this is a comment --><child/></root>")
	ok(eq(#doc.children, 1), "should have 1 root")
	ok(eq(doc.children[1].tag, "root"), "root tag")
	ok(eq(#doc.children[1].children, 1), "should have 1 child (comment removed)")
	ok(eq(doc.children[1].children[1].tag, "child"), "child tag")
end)

test("ordered attributes are preserved", function()
	local doc = xml.parse("<item z=\"3\" a=\"1\" m=\"2\"/>")
	ok(eq(#doc.children[1].orderedattrs, 3), "should have 3 ordered attrs")
	ok(eq(doc.children[1].orderedattrs[1].name, "z"), "first attr name")
	ok(eq(doc.children[1].orderedattrs[1].value, "3"), "first attr value")
	ok(eq(doc.children[1].orderedattrs[2].name, "a"), "second attr name")
	ok(eq(doc.children[1].orderedattrs[2].value, "1"), "second attr value")
	ok(eq(doc.children[1].orderedattrs[3].name, "m"), "third attr name")
	ok(eq(doc.children[1].orderedattrs[3].value, "2"), "third attr value")
end)

test("attributes with single quotes", function()
	local doc = xml.parse("<item name='value'/>")
	ok(eq(doc.children[1].attrs.name, "value"), "should parse single-quoted attr")
end)

test("tags with namespaces", function()
	local doc = xml.parse("<ns:element ns:attr='value'/>")
	ok(eq(doc.children[1].tag, "ns:element"), "tag with namespace")
	ok(eq(doc.children[1].attrs["ns:attr"], "value"), "attr with namespace")
end)

test("tags with hyphens and underscores", function()
	local doc = xml.parse("<my-element my_attr='test'/>")
	ok(eq(doc.children[1].tag, "my-element"), "tag with hyphen")
	ok(eq(doc.children[1].attrs.my_attr, "test"), "attr with underscore")
end)

test("empty document", function()
	local doc = xml.parse("")
	ok(eq(#doc.children, 0), "should have no children")
end)

test("whitespace in content", function()
	local doc = xml.parse("<root>  some text here  </root>")
	ok(eq(doc.children[1].tag, "root"), "root tag parsed")
end)

test("wayland-like protocol structure", function()
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
	ok(eq(protocol.tag, "protocol"), "protocol tag")
	ok(eq(protocol.attrs.name, "test_protocol"), "protocol name")
	local interface = protocol.children[1]
	ok(eq(interface.tag, "interface"), "interface tag")
	ok(eq(interface.attrs.name, "test_interface"), "interface name")
	ok(eq(interface.attrs.version, "1"), "interface version")
	local request = interface.children[1]
	ok(eq(request.tag, "request"), "request tag")
	ok(eq(request.attrs.name, "create_surface"), "request name")
	local request_arg = request.children[1]
	ok(eq(request_arg.tag, "arg"), "request arg tag")
	ok(eq(request_arg.attrs.name, "id"), "request arg name")
	ok(eq(request_arg.attrs.type, "new_id"), "request arg type")
	ok(eq(request_arg.attrs.interface, "test_surface"), "request arg interface")
	local event = interface.children[2]
	ok(eq(event.tag, "event"), "event tag")
	ok(eq(event.attrs.name, "configure"), "event name")
	local enum = interface.children[3]
	ok(eq(enum.tag, "enum"), "enum tag")
	ok(eq(enum.attrs.name, "error"), "enum name")
	local entry = enum.children[1]
	ok(eq(entry.tag, "entry"), "entry tag")
	ok(eq(entry.attrs.name, "invalid"), "entry name")
	ok(eq(entry.attrs.value, "0"), "entry value")
end)

test("xml declaration", function()
	local doc = xml.parse("<?xml version=\"1.0\"?><root/>")
	ok(eq(doc.children[1].tag, "root"), "xml declaration should not break parsing")
end)

test("doctype declaration", function()
	local doc = xml.parse("<!DOCTYPE html><html/>")
	ok(eq(doc.children[1].tag, "html"), "doctype should not break parsing")
end)

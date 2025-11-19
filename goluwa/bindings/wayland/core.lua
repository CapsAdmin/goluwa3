local ffi = require("ffi")
local wayland = {}
-- Wayland core types and functions (libwayland-client)
ffi.cdef[[
	typedef int32_t wl_fixed_t;
	
	struct wl_interface;
	
	struct wl_message {
		const char *name;
		const char *signature;
		const struct wl_interface **types;
	};
	
	struct wl_interface {
		const char *name;
		int version;
		int method_count;
		const struct wl_message *methods;
		int event_count;
		const struct wl_message *events;
	};
	
	struct wl_display;
	struct wl_registry;
	struct wl_proxy;
	struct wl_array;
	
	// Core functions
	struct wl_display *wl_display_connect(const char *name);
	void wl_display_disconnect(struct wl_display *display);
	int wl_display_dispatch(struct wl_display *display);
	int wl_display_dispatch_pending(struct wl_display *display);
	int wl_display_roundtrip(struct wl_display *display);
	int wl_display_flush(struct wl_display *display);
	int wl_display_get_fd(struct wl_display *display);
	int wl_display_get_error(struct wl_display *display);
	uint32_t wl_display_get_protocol_error(struct wl_display *display, const struct wl_interface **interface, uint32_t *id);
	
	// Proxy functions
	void *wl_proxy_create(void *factory, const struct wl_interface *interface);
	void wl_proxy_destroy(void *proxy);
	void *wl_proxy_marshal_constructor(void *proxy, uint32_t opcode, const struct wl_interface *interface, ...);
	void *wl_proxy_marshal_constructor_versioned(void *proxy, uint32_t opcode, const struct wl_interface *interface, uint32_t version, ...);
	void wl_proxy_marshal(void *p, uint32_t opcode, ...);
	
	// Array proxy functions
	union wl_argument {
		int32_t i;
		uint32_t u;
		int32_t f;
		const char *s;
		struct wl_object *o;
		uint32_t n;
		struct wl_array *a;
		int32_t h;
	};
	void wl_proxy_marshal_array(struct wl_proxy *p, uint32_t opcode, union wl_argument *args);
	void *wl_proxy_marshal_array_constructor(struct wl_proxy *proxy, uint32_t opcode, union wl_argument *args, const struct wl_interface *interface);
	void *wl_proxy_marshal_array_constructor_versioned(struct wl_proxy *proxy, uint32_t opcode, union wl_argument *args, const struct wl_interface *interface, uint32_t version);

	int wl_proxy_add_listener(void *proxy, void (**implementation)(void), void *data);
	void wl_proxy_set_user_data(void *proxy, void *user_data);
	void *wl_proxy_get_user_data(void *proxy);
	uint32_t wl_proxy_get_version(void *proxy);
	const struct wl_interface *wl_proxy_get_interface(void *proxy);
	
	// XKB types
	struct xkb_context;
	struct xkb_keymap;
	struct xkb_state;
	
	struct xkb_context *xkb_context_new(int flags);
	void xkb_context_unref(struct xkb_context *context);
	struct xkb_keymap *xkb_keymap_new_from_string(struct xkb_context *context, const char *string, int format, int flags);
	void xkb_keymap_unref(struct xkb_keymap *keymap);
	struct xkb_state *xkb_state_new(struct xkb_keymap *keymap);
	void xkb_state_unref(struct xkb_state *state);
	uint32_t xkb_state_key_get_one_sym(struct xkb_state *state, uint32_t key);
	int xkb_state_update_mask(struct xkb_state *state, uint32_t depressed_mods, uint32_t latched_mods, uint32_t locked_mods, uint32_t depressed_layout, uint32_t latched_layout, uint32_t locked_layout);
	
	// System
	void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset);
	int munmap(void *addr, size_t length);
	int close(int fd);
	
	struct pollfd {
		int fd;
		short events;
		short revents;
	};
	int poll(struct pollfd *fds, unsigned long nfds, int timeout);
]]
require("bindings.wayland.rebuild")
wayland.xkb = ffi.load("xkbcommon", true) -- load globally
wayland.wl_client = ffi.load("wayland-client", true) -- load globally
-- Load generated bindings
require("bindings.wayland.wayland")
local xdg_bindings = require("bindings.wayland.xdg_shell")

function wayland.get_interface(name)
	local iface_ptr = ffi.C[name .. "_interface"]
	return {name = name, ptr = iface_ptr}
end

function wayland.get_xdg_interface(name)
	return xdg_bindings.get_interface(name)
end

return wayland

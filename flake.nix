{
  description = "Goluwa3 - Vulkan 3D engine with LuaJIT and FFI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        luajit = pkgs.stdenv.mkDerivation {
          name = "luajit";
          src = pkgs.fetchgit {
            url = "https://github.com/LuaJIT/LuaJIT.git";
            rev = "45b771bb2c693a4cc7e34e79b7d30ab10bb7776a";
            sha256 = "sha256-VR69KuUXQD6aICVNuBafdthCD558/Ri4haH2LY9AXcU=";
          };

          buildInputs = [pkgs.makeWrapper];

          makeFlags = ["PREFIX=$(out)" "XCFLAGS=-DLUAJIT_ENABLE_LUA52COMPAT" "BUILDMODE=static"];

          buildPhase = ''
            make amalg PREFIX=$out XCFLAGS="-DLUAJIT_ENABLE_LUA52COMPAT" BUILDMODE=static
          '';

          installPhase = ''
            make install PREFIX=$out
            ln -sf $out/bin/luajit-2.1.ROLLING $out/bin/luajit
          '';
        };
        
        openresty-gdb-utils = pkgs.fetchgit {
          url = "https://github.com/Revolyssup/openresty-gdb-utils.git";
          rev = "c87bcc56aef37bc823f352b20c8b57ddd979c4e9";
          sha256 = "sha256-vJEmxquj15Im9q2fjt8qNiuanxh/j8+oqNuZnoQA9I8=";
        };
        
        luajit-debug = pkgs.stdenv.mkDerivation {
          name = "luajit-debug";
          src = pkgs.fetchgit {
            url = "https://github.com/LuaJIT/LuaJIT.git";
            rev = "45b771bb2c693a4cc7e34e79b7d30ab10bb7776a";
            sha256 = "sha256-VR69KuUXQD6aICVNuBafdthCD558/Ri4haH2LY9AXcU=";
          };

          buildInputs = [pkgs.makeWrapper];

          buildPhase = ''
            make amalg PREFIX=$out \
              XCFLAGS="-DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_ENABLE_TABLE_BUMP -DLUA_USE_ASSERT -DLUA_USE_APICHECK" \
              CCDEBUG="-g -O0" \
              BUILDMODE=static
          '';

          installPhase = ''
            make install PREFIX=$out
            mv $out/bin/luajit-2.1.ROLLING $out/bin/luajit_debug
            rm -f $out/bin/luajit
          '';
        };
      in
      {
        devShells.default = pkgs.mkShell {
          name = "goluwa3-dev";
          
          buildInputs = with pkgs; [
            # Lua runtime
            luajit
            luajit-debug
            
            # Vulkan development
            vulkan-headers
            vulkan-loader
            vulkan-validation-layers
            vulkan-tools        # vulkaninfo
            shaderc             # GLSL to SPIRV compiler - glslc
            vulkan-tools-lunarg # vkconfig
            mesa                # lavapipe CPU-based Vulkan implementation
            
            # Wayland development
            wayland
            wayland-protocols
            wayland-scanner
            libxkbcommon
            
            # TLS/SSL support
            openssl
            
            # Development and debugging tools
            renderdoc           # Graphics debugger
            tracy               # Graphics profiler
            gdb                 # GNU debugger
          ];

          LD_LIBRARY_PATH = with pkgs; "${vulkan-loader}/lib:${vulkan-validation-layers}/lib:${shaderc.lib}/lib:${wayland}/lib:${libxkbcommon}/lib:${renderdoc}/lib:${openssl.out}/lib:${mesa}/lib";
          VULKAN_SDK = "${pkgs.vulkan-headers}";
          VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
          RENDERDOC_LIB = "${pkgs.renderdoc}/lib/librenderdoc.so";
          
          # Wayland environment
          XDG_RUNTIME_DIR = "/run/user/1000";
          WAYLAND_DISPLAY = "wayland-0";
          
          # Prepend RenderDoc bin to PATH so LaunchReplayUI can find qrenderdoc
          shellHook = ''
            export PATH="${pkgs.renderdoc}/bin:$PATH"
            export OPENRESTY_GDB="${openresty-gdb-utils}"
            
            ljgdb() {
              PYTHONPATH="${openresty-gdb-utils}:$PYTHONPATH" gdb -q \
                -ex "source ${openresty-gdb-utils}/luajit21.py" \
                --args luajit_debug "$@"
            }
          '';
        };
      }
    );
}
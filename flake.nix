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
            rev = "e17ee83326f73d2bbfce5750ae8dc592a3b63c27";
            sha256 = "sha256-L76xdhQOeda4rtKJhGHNBkk9CdEpH5t+PZEobHkzzcE=";
          };

          buildInputs = [pkgs.makeWrapper];

          makeFlags = ["PREFIX=$(out)"];

          installPhase = ''
            make install PREFIX=$out
            ln -sf $out/bin/luajit-2.1.ROLLING $out/bin/luajit
          '';
        };
      in
      {
        devShells.default = pkgs.mkShell {
          name = "goluwa3-dev";
          
          buildInputs = with pkgs; [
            # Lua runtime
            luajit
            
            # Vulkan development
            vulkan-headers
            vulkan-loader
            vulkan-validation-layers
            vulkan-tools        # vulkaninfo
            shaderc             # GLSL to SPIRV compiler - glslc
            vulkan-tools-lunarg # vkconfig
            
            # Development and debugging tools
            renderdoc           # Graphics debugger
            tracy               # Graphics profiler
          ];

          LD_LIBRARY_PATH = with pkgs; "${vulkan-loader}/lib:${vulkan-validation-layers}/lib:${shaderc.lib}/lib";
          VULKAN_SDK = "${pkgs.vulkan-headers}";
          VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
        };
      }
    );
}
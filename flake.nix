{
  description = "4D space explorer: Zig + AMD HIP";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          pkgs.zig
          pkgs.rocmPackages.clr        # HIP runtime: libamdhip64.so + headers
          pkgs.rocmPackages.hipcc      # compiles the .hip device kernels
          pkgs.rocmPackages.rocminfo   # `rocminfo | grep gfx` finds the offload arch
          pkgs.SDL2
          pkgs.imagemagick             # converts --screenshot PPMs to PNG
        ];

        # Read by build.zig. (SDL2_PATH would get clobbered by SDL2's setup hook.)
        ROCM_PREFIX = "${pkgs.rocmPackages.clr}";
        SDL2_PREFIX = "${pkgs.SDL2}";

        shellHook = ''
          export HIP_PATH="${pkgs.rocmPackages.clr}"
          # sdl2-compat dlopens SDL3 at startup. The host's LD_LIBRARY_PATH is
          # deliberately not inherited: libraries built against a different
          # glibc than this flake's break loading.
          export LD_LIBRARY_PATH="${pkgs.rocmPackages.clr}/lib:${pkgs.SDL2}/lib:${pkgs.sdl3}/lib"
        '';
      };
    };
}

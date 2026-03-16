{
  description = "Entwicklungsumgebung";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    naersk.url = "github:nix-community/naersk";
    gastown-src = {
      url = "github:Wenjix/gastown";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, naersk, gastown-src }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      naersk-lib = pkgs.callPackage naersk { };

      # Gastown Paket Definition
      gastown-pkg = naersk-lib.buildPackage {
        src = gastown-src;
        nativeBuildInputs = with pkgs; [ pkg-config clang ];
        buildInputs = with pkgs; [ openssl ];
        LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
      };
    in
    {
      # Pakete exportieren
      packages.${system}.default = gastown-pkg;

      devShells.${system} = {
        # Bestehende Shell (aufrufbar via: nix develop .#age)
        age = pkgs.mkShell {
          buildInputs = with pkgs; [
            age
            sops
            fluxcd
          ];
          shellHook = ''
            [ -d "dns" ] && cd dns
            echo "Age/Sops Umgebung bereit."
          '';
        };

        # Neue kombinierte Shell (aufrufbar via: nix develop)
        default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Ansible/Age Tools
            age
            sops
            fluxcd
            # Gastown & Rust Tools
            gastown-pkg
            cargo
            rustc
          ];

          shellHook = ''
            export LIBCLANG_PATH="${pkgs.llvmPackages.libclang.lib}/lib"
            echo "Kombinierte Umgebung geladen: Ansible-Tools & Gastown verfügbar."
          '';
        };
      };
    };
}

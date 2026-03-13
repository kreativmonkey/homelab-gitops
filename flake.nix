{
  description = "Ansible Schulung Entwicklungsumgebung";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    age =
      pkgs.mkShell
        {
        # Required packages
        buildInputs = [
          pkgs.age
          pkgs.sops
          pkgs.fluxcd
        ];

        # Shell hook replicates Dockerfile steps
        shellHook = ''
          cd dns
        '';
        };
  };
}

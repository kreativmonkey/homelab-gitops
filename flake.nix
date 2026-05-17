{
  description = "GitOps Homelab – Entwicklungs- und CI-Umgebung";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      ciTools = with pkgs; [
        yamllint
        kubeconform
        kustomize
        kubectl
        kubernetes-helm
        kind
        yq-go
        fluxcd
        age
        sops
      ];
    in
    {
      devShells.${system} = {
        age = pkgs.mkShell {
          buildInputs = with pkgs; [ age sops fluxcd ];
          shellHook = ''
            echo "Age/Sops Umgebung bereit."
          '';
        };

        default = pkgs.mkShell {
          buildInputs = ciTools;
          shellHook = ''
            echo "GitOps CI-Umgebung: yamllint, kubeconform, kustomize, helm, kind"
            echo "Tests: ./scripts/ci/validate.sh  |  SKIP_KIND=1 für Stages 1–2"
          '';
        };
      };

      checks.${system}.validation = pkgs.runCommand "gitops-validation" {
        nativeBuildInputs = ciTools;
        src = ./.;
      } ''
        cp -r $src source
        cd source
        export SKIP_KIND=1
        ${pkgs.bash}/bin/bash scripts/ci/validate.sh
        touch $out
      '';
    };
}

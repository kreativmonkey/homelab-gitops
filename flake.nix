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
        talosctl
        yq-go
        fluxcd
        age
        sops
        just
        gitleaks
        trivy
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
            echo "GitOps CI-Umgebung: just, yamllint, kubeconform, kustomize, helm, kind, talosctl, sops"
            echo "  just --list          # alle Befehle"
            echo "  just validate        # schema-only stages (Forgejo / GitHub PR workflow)"
            echo "  just validate-full   # + server-dry-run (kind, or talos via CLUSTER_PROVISIONER=talos)"
          '';
        };
      };

    };
}

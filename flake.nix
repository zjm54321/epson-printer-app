{
  description = "Local static checks for the Epson Printer Application image";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = with pkgs; [ python3 git curl gh shellcheck actionlint ];
        shellHook = ''
          echo "Static checks: python3 scripts/check-static.py"
          echo "Image builds and publication run on GitHub's ubuntu-24.04 runner."
        '';
      };
    };
}

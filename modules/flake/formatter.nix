# `nix fmt` and the format check run by `nix flake check`, for this flake's
# own tree (nixfmt, RFC 166 style).
{
  perSystem =
    { pkgs, ... }:
    let
      inherit (pkgs) lib;
      root = ../..;
    in
    {
      # `nix fmt` formats every tracked .nix file of the flake it runs in (the
      # nearest directory above the working directory with a flake.nix), or
      # only the files given.
      formatter = pkgs.writeShellScriptBin "nixos-base-fmt" ''
        if [ "$#" -eq 0 ]; then
          dir=$PWD
          until [ -e "$dir/flake.nix" ] || [ "$dir" = / ]; do dir=$(dirname "$dir"); done
          cd "$dir"
          ${pkgs.git}/bin/git ls-files -z -- '*.nix' \
            | ${pkgs.findutils}/bin/xargs -0 -r ${pkgs.nixfmt}/bin/nixfmt
        else
          exec ${pkgs.nixfmt}/bin/nixfmt "$@"
        fi
      '';

      # Rebuilds only when a .nix file changes.
      checks.format =
        pkgs.runCommand "nixos-base-format-check"
          {
            src = lib.fileset.toSource {
              inherit root;
              fileset = lib.fileset.fileFilter (f: f.hasExt "nix") root;
            };
          }
          ''
            cd "$src"
            find . -name '*.nix' -print0 | xargs -0 ${pkgs.nixfmt}/bin/nixfmt --check
            touch "$out"
          '';
    };
}

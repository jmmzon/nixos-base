# Vicinae launcher: the package, its privileged input-server wrapper (for
# paste and snippets), the user service started with the session, the
# launcher opacity from home/appearance.nix and, with my.bitwarden.email set,
# the store's Bitwarden extension on top of rbw.
{ inputs, ... }:
{
  flake.modules.nixos.vicinae =
    { pkgs, ... }:
    {
      imports = [ inputs.vicinae.nixosModules.default ];
      environment.systemPackages = [
        inputs.vicinae.packages.${pkgs.stdenv.hostPlatform.system}.default
      ];
    };

  flake.modules.homeManager.vicinae =
    {
      config,
      lib,
      osConfig,
      pkgs,
      ...
    }:
    let
      system = pkgs.stdenv.hostPlatform.system;
      vicinae = inputs.vicinae.packages.${system}.default;
      bitwardenEmail = osConfig.my.bitwarden.email;
      # "Browse Bitwarden Vault": search, copy or paste passwords, usernames
      # and TOTP codes through rbw. rbw-agent keeps the unlocked keys in
      # memory only; the extension's Unlock action opens rbw's pinentry.
      bitwardenExtension = inputs.vicinae.lib.${system}.mkVicinaeExtension {
        pname = "bitwarden";
        version = "0-unstable-2026-10-09";
        src = "${inputs.vicinae-extensions}/extensions/bitwarden";
      };
    in
    {
      programs.rbw = lib.mkIf (bitwardenEmail != null) {
        enable = true;
        settings = {
          email = bitwardenEmail;
          lock_timeout = 3600;
          pinentry = pkgs.pinentry-qt;
        };
      };
      xdg.dataFile."vicinae/extensions/bitwarden" = lib.mkIf (bitwardenEmail != null) {
        source = bitwardenExtension;
      };

      # Vicinae's GUI rewrites settings.json, so the Nix-managed values live in
      # an import it lists ("imports": ["./nix.json"]); settings.json still wins
      # for any key it sets itself. nix.json is the launcher opacity for the
      # current theme mode, picked by erebor-theme-opacity (home/theme-opacity.nix).
      xdg.configFile."vicinae/nix.json".source =
        config.lib.file.mkOutOfStoreSymlink "${config.xdg.stateHome}/erebor-theme-opacity/vicinae.json";
      xdg.configFile."systemd/user/graphical-session.target.wants/vicinae.service".source =
        "${vicinae}/share/systemd/user/vicinae.service";
      xdg.configFile."systemd/user/vicinae.service.d/override.conf".text = ''
        [Service]
        ExecStart=
        ExecStart=${vicinae}/bin/vicinae server --replace
      '';
    };
}

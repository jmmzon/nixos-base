# Ghostty's config. On Linux it uses Noctalia's generated theme and the shared
# opacity; on macOS, which has no Noctalia, home/ghostty/config-macos.ghostty
# with a fixed theme. Ghostty itself comes from the system or a Homebrew cask.
#
# On Linux a second, background Ghostty instance with its own class owns the
# quake-style quick terminal (a layer-shell surface), so ordinary Ghostty
# windows keep their own processes. Toggle it by calling its GAction (bound in
# the compositor); D-Bus activation starts the service when needed:
#   busctl --user call com.mitchellh.ghostty.quick /com/mitchellh/ghostty/quick \
#     org.gtk.Actions Activate 'sava{sv}' toggle-quick-terminal 0 0
# Ghostty 1.4.0's `+toggle-quick-terminal --class=…` ignores --class and
# toggles the default instance instead.
{
  flake.modules.homeManager.ghostty =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    lib.mkMerge [
      {
        xdg.configFile."ghostty/config.ghostty".source =
          if pkgs.stdenv.hostPlatform.isDarwin then
            ../../home/ghostty/config-macos.ghostty
          else
            pkgs.replaceVars ../../home/ghostty/config.ghostty {
              appOpacity = (import ./_opacity.nix lib).dark.value;
              fontFamily = (pkgs.callPackage ../../packages/xenon-code { }).family;
              opacityFile = "${config.xdg.stateHome}/erebor-theme-opacity/ghostty";
            };
      }
      (lib.mkIf pkgs.stdenv.hostPlatform.isLinux (
        let
          quickClass = "com.mitchellh.ghostty.quick";
          unit = "ghostty-quick-terminal.service";
        in
        {
          systemd.user.services.ghostty-quick-terminal = {
            Unit = {
              Description = "Ghostty quick (drop-down) terminal";
              PartOf = [ "graphical-session.target" ];
              After = [
                "graphical-session.target"
                "dbus.socket"
              ];
              Requires = [ "dbus.socket" ];
            };
            Service = {
              Type = "notify-reload";
              ReloadSignal = "SIGUSR2";
              BusName = quickClass;
              ExecStart = lib.concatStringsSep " " [
                "${pkgs.ghostty}/bin/ghostty"
                "--class=${quickClass}"
                "--gtk-single-instance=true"
                "--initial-window=false"
                "--quit-after-last-window-closed=false"
              ];
              Restart = "on-failure";
            };
            Install.WantedBy = [ "graphical-session.target" ];
          };

          # Lets the toggle above start the service on demand.
          xdg.dataFile."dbus-1/services/${quickClass}.service".text = ''
            [D-BUS Service]
            Name=${quickClass}
            SystemdService=${unit}
            Exec=${pkgs.coreutils}/bin/false
          '';
        }
      ))
    ];
}

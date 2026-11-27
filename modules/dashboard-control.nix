# The dashboard (the erebor-dashboard flake input) and its control settings.
# Its cards come from my.dashboard.settingsFile (default
# home/dashboard-settings.json), placeholders filled in.
{ inputs, ... }:
{
  flake.modules.nixos.dashboard-control = {
    imports = [
      inputs.dashboard.nixosModules.default
      (
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          user = config.my.user.name;
          domain = config.my.network.domain;
          my = config.my;
          ambilightActions = [
            "ambilight-on"
            "ambilight-off"
          ];
          # Drop buttons for hardware this machine does not have.
          keepAction =
            a: (my.ambilight.enable || !(lib.elem a ambilightActions)) && (my.nanokvm.enable || a != "wake");
          host = config.networking.hostName;
          # With erebor-sysd the dashboard's power and Windows actions go through its
          # policy, and the polkit grants move to sysd's user (control-daemon).
          viaSysd = my.controlDaemon.enable;
          baseSettings = builtins.fromJSON (
            builtins.replaceStrings
              [ "@host@" "@Host@" "@domain@" "@domainSuffix@" ]
              [
                host
                (lib.toUpper (lib.substring 0 1 host) + lib.substring 1 (-1) host)
                domain
                (lib.removePrefix (lib.head (lib.splitString "." domain)) domain)
              ]
              (builtins.readFile my.dashboard.settingsFile)
          );
        in
        {
          # Only this fixed operation can write the GRUB one-time selection.
          systemd.services.dashboard-reboot-windows = {
            description = "Reboot once into the existing Windows GRUB entry";
            path = [
              pkgs.grub2_efi
              pkgs.util-linux
              pkgs.coreutils
              pkgs.systemd
            ];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${pkgs.python3}/bin/python3 ${my.windowsReboot.script}";
              TimeoutStartSec = 60;
              NoNewPrivileges = true;
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              ReadWritePaths = [ "/boot/grub/grubenv" ];
              RestrictAddressFamilies = [ "AF_UNIX" ];
              CapabilityBoundingSet = "";
              UMask = "0077";
            };
          };
          assertions = [
            {
              assertion = viaSysd -> lib.any (c: lib.elem user c.users) (lib.attrValues my.controlDaemon.callers);
              message = "dashboard-control: with my.controlDaemon, ${user} (the dashboard's user) must be one of my.controlDaemon.callers.";
            }
          ];
          security.polkit.extraConfig = lib.mkIf (!viaSysd) ''
            polkit.addRule(function(action, subject) {
              if (subject.user == "${user}" &&
                  action.id == "org.freedesktop.systemd1.manage-units" &&
                  action.lookup("unit") == "dashboard-reboot-windows.service" &&
                  action.lookup("verb") == "start") {
                return polkit.Result.YES;
              }
              // The dashboard API runs outside an active session, which the default policy requires.
              if (subject.user == "${user}" &&
                  action.id == "org.freedesktop.UPower.PowerProfiles.switch-profile") {
                return polkit.Result.YES;
              }
            });
          '';

          services.erebor-dashboard = {
            enable = true;
            settings =
              baseSettings
              // {
                actions = lib.filter keepAction baseSettings.actions;
              }
              // lib.optionalAttrs (my.nanokvm.enable && my.nanokvm.url != null) {
                wakeUrl = "${my.nanokvm.url}/wake";
                outletUrl = "${my.nanokvm.url}/outlet";
              };
            control = {
              enable = true;
              user = "${user}";
              allowedHosts = [
                "${config.networking.hostName}"
                "localhost"
                "127.0.0.1"
                "${config.networking.hostName}.local"
                "${domain}"
              ];
              enabledActions = lib.filter keepAction [
                "display-on"
                "display-off"
                "screen-dp"
                "screen-hdmi"
                "ambilight-on"
                "ambilight-off"
                "profile-performance"
                "profile-balanced"
                "profile-power-saver"
                "sleep"
                "power-off"
                "reboot-windows"
                "moonshine-pair"
              ];
              # The board reads the live checkout; only the script itself is pinned.
              tasks = lib.mkIf my.taskBoard.enable {
                command = [
                  (lib.getExe pkgs.python3)
                  "${my.taskBoard.script}"
                  "--root"
                  my.flakePath
                  "list"
                  "--json"
                ];
                linkBase = if my.taskBoard.linkBase == null then "" else my.taskBoard.linkBase;
              };
              wledUrl = lib.mkIf (my.ambilight.enable && my.ambilight.wledUrl != null) my.ambilight.wledUrl;
              # Profile and Ambilight cards say what power-saver changed (erebor-modes, SYS-122).
              systemDaemon = lib.mkIf viaSysd "/run/erebor/sysd.sock";
              modesState = lib.mkIf my.modes.enable "${
                config.users.users.${user}.home
              }/.local/state/erebor-modes/state.json";
              # The same helper backs the Noctalia bar's screen switch.
              extraPackages = [
                config.programs.umbriel.package
                (pkgs.callPackage ../packages/umbriel-display-mode.nix { })
              ];
            };
          };
        }
      )
    ];
  };
}

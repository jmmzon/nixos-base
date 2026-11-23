# uinput access and the xremap key remapper (imported per host), and the
# keymap it reads (home/xremap).
let
  # File names under ~/.config/xremap, in load order: the base keymap when
  # my.xremap.config is null, else each listed file under its own name.
  keymapNames =
    files: if files == null then [ "config.yml" ] else map (f: baseNameOf (toString f)) files;
in
{
  flake.modules.nixos.xremap =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      user = config.my.user.name;
      cfg = config.my.xremap;
      deviceArgs = lib.concatMapStrings (d: "--device \"${d.name}\" ") cfg.devices;
      hotplugUsb = lib.unique (lib.filter (usb: usb != null) (map (d: d.usb) cfg.devices));
      names = keymapNames cfg.config;
      configArgs = lib.concatMapStringsSep " " (n: "/home/${user}/.config/xremap/${n}") names;
    in
    {
      options.my.xremap = {
        devices = lib.mkOption {
          # A plain string is shorthand for { name = "..."; }.
          type = lib.types.listOf (
            lib.types.coercedTo lib.types.str (name: { inherit name; }) (
              lib.types.submodule {
                options = {
                  name = lib.mkOption {
                    type = lib.types.str;
                    example = "RDR IQUNIX MQ80 KB";
                    description = "Input device name xremap grabs (see `xremap --list-devices`).";
                  };
                  usb = lib.mkOption {
                    type = lib.types.nullOr (
                      lib.types.submodule {
                        options.vendor = lib.mkOption {
                          type = lib.types.str;
                          example = "320f";
                          description = "USB vendor ID (`lsusb`, before the colon).";
                        };
                        options.product = lib.mkOption {
                          type = lib.types.str;
                          example = "5055";
                          description = "USB product ID (`lsusb`, after the colon).";
                        };
                      }
                    );
                    default = null;
                    description = "When set, plugging this USB device in restarts xremap so it grabs the device again.";
                  };
                };
              }
            )
          );
          default = [ ];
          description = "Devices xremap remaps.";
        };
      };

      config = {
        assertions = [
          {
            assertion = lib.allUnique names;
            message = "my.xremap.config: keymap files need distinct names (${toString names}).";
          }
        ];

        services.udev.extraRules = ''
          KERNEL=="uinput", GROUP="input", MODE="0660", TAG+="uaccess"
        ''
        + lib.concatMapStrings (usb: ''
          ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="${usb.vendor}", ATTR{idProduct}=="${usb.product}", TAG+="systemd", ENV{SYSTEMD_USER_WANTS}+="xremap-restart.service"
        '') hotplugUsb;

        systemd.user.services.xremap = {
          description = "xremap key remapper";
          # Apps launched by xremap inherit this PATH. Keep the setuid wrappers first
          # and use profile links, not store paths, so sudo works and survives rebuilds.
          environment.PATH = lib.mkForce "/run/wrappers/bin:/home/${user}/.local/bin:/home/${user}/.nix-profile/bin:/etc/profiles/per-user/${user}/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin";
          after = [ "graphical-session.target" ];
          partOf = [ "graphical-session.target" ];
          wantedBy = [ "graphical-session.target" ];
          serviceConfig = {
            # xremap >= 0.15.17 auto-detects the desktop once at startup and keeps
            # "none" if the compositor is not up yet, which disables every
            # application-scoped keymap. wlroots connects on first use and covers
            # Umbriel (wlr-foreign-toplevel).
            ExecStart = "${pkgs.xremap}/bin/xremap --desktop wlroots --allow-launch true --mouse ${deviceArgs}${configArgs}";
            Restart = "on-failure";
          };
        };

        systemd.user.services.xremap-restart = {
          description = "Restart xremap after keyboard connection";
          serviceConfig = {
            Type = "oneshot";
            # try-restart: a keyboard seen at boot must not start xremap before the
            # graphical session does.
            ExecStart = "${pkgs.systemd}/bin/systemctl --user try-restart xremap.service";
          };
        };
      };
    };

  # The keymap and its launcher helper; deployed for the user on every host.
  # my.xremap.config replaces the base keymap, whose launchers are under @home@.
  flake.modules.homeManager.xremap =
    {
      config,
      lib,
      osConfig,
      pkgs,
      ...
    }:
    let
      files = osConfig.my.xremap.config;
      sources =
        if files == null then
          [ (pkgs.replaceVars ../home/xremap/config.yml { home = config.home.homeDirectory; }) ]
        else
          files;
    in
    {
      xdg.configFile = lib.listToAttrs (
        lib.zipListsWith (name: source: {
          name = "xremap/${name}";
          value.source = source;
        }) (keymapNames files) sources
      );
      home.file.".local/bin/xremap-focus-or-launch" = {
        source = ../home/xremap/focus-or-launch;
        executable = true;
      };
    };
}

# Per-machine settings. Each host sets these in modules/hosts/<name>/default.nix;
# shared modules read them instead of hard-coding one machine's values.
# Every setting is a group, so a new option can join it without renaming.
{
  flake.modules.nixos.my =
    {
      pkgs,
      config,
      lib,
      ...
    }:

    let
      cfg = config.my;
      urlType = lib.types.strMatching "https?://[^ ]+";
      enabledServices = lib.filterAttrs (_: s: s.enable) cfg.services;
      # Enabled services that claim the same value of `attr`, as "a, b uses N".
      clashes =
        attr:
        lib.mapAttrsToList (value: names: "${lib.concatStringsSep ", " names} use ${value}") (
          lib.filterAttrs (_: names: lib.length names > 1) (
            lib.groupBy' (names: name: names ++ [ name ]) [ ] (name: toString enabledServices.${name}.${attr}) (
              lib.filter (name: enabledServices.${name}.${attr} != null) (lib.attrNames enabledServices)
            )
          )
        );
      serviceType = lib.types.submodule (
        { name, ... }: {
          options = {
            enable = lib.mkEnableOption "the ${name} service, with its web routes and LAN port";
            port = lib.mkOption {
              type = lib.types.port;
              description = "Loopback port Caddy proxies to.";
            };
            localName = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "jellyfin";
              description = "Bare name served on :80 as `<name>` and `<name>.localhost`, also added to /etc/hosts.";
            };
            publicName = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "media";
              description = "Subdomain of my.network.domain served over HTTPS.";
            };
            lanPort = lib.mkOption {
              type = lib.types.nullOr lib.types.port;
              default = null;
              description = "Plain-HTTP port Caddy listens on, opened on the LAN interface.";
            };
            proxy = {
              headers = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                example = [
                  "Host localhost:18384"
                  "-Authorization"
                ];
                description = "`header_up` arguments for the local and public routes.";
              };
              lanHeaders = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = config.my.services.${name}.proxy.headers;
                defaultText = lib.literalExpression "proxy.headers";
                description = "`header_up` arguments for the LAN port block.";
              };
              https = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "The upstream speaks HTTPS.";
              };
              tlsInsecure = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Skip upstream certificate checks (self-signed loopback HTTPS).";
              };
            };
            extraConfig = lib.mkOption {
              type = lib.types.lines;
              default = "";
              description = "Caddy directives placed before reverse_proxy in the public route.";
            };
          };
        }
      );
    in
    {
      options.my = {
        services = lib.mkOption {
          type = lib.types.attrsOf serviceType;
          default = { };
          description = ''
            Web services behind Caddy. Each modules/services file declares its
            entry; hosts set `my.services.<name>.enable`. Routes, /etc/hosts names
            and LAN firewall ports are generated from this registry.
          '';
        };

        flakePath = lib.mkOption {
          type = lib.types.nullOr (lib.types.strMatching "/.*");
          default = null;
          example = "/etc/nixos";
          description = ''
            Checkout of this repository that live desktop configs link to
            (Umbriel, Noctalia, the Zed keymap). Home Manager points
            those files at it with out-of-store symlinks, so saving the file there
            applies the change without a rebuild. Null links the store copies
            instead (no checkout needed; edits need a rebuild); my.taskBoard,
            my.shellTasks and my.updateBranch, which read the checkout, then cannot
            be enabled.
          '';
        };

        secretsFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = lib.literalExpression "../../../secrets/myhost.yaml";
          description = ''
            The host's sops-encrypted secrets (sops.defaultSopsFile), decrypted with
            its SSH host key at activation. Null declares no secrets file, so
            features that need a secret (my.network.ovhDns, the ollama service's
            SearXNG) cannot be enabled.
          '';
        };

        taskBoard = {
          enable = lib.mkEnableOption ''
            the read-only task card in the dashboard hub for administrators. The
            control API runs `my.taskBoard.script --root <flakePath> list --json`
            with Python, so the counts follow the checkout without a rebuild. Needs
            my.taskBoard.script and my.flakePath
          '';
          script = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            example = lib.literalExpression "../../../scripts/tasks";
            description = ''
              Python task script the task card runs; pinned in the store. It is
              called as `<script> --root <checkout> list --json` and prints the
              task list as JSON (the dashboard's task card format).
            '';
          };
          linkBase = lib.mkOption {
            type = lib.types.nullOr urlType;
            default = null;
            example = "https://github.com/owner/nixos-config/blob/master/";
            description = "URL prefix that makes task file paths (tasks/SYS-NNN.md) into links; null shows no links.";
          };
        };

        shellTasks = {
          enable = lib.mkEnableOption ''
            a task board under the fish welcome banner, read live from
            `<flakePath>/tasks` with `my.taskBoard.script --root <flakePath> list --json`
            (hidden while that directory is missing), and the task script on PATH
            under its own file name, alias `et`, reading my.flakePath when run
            outside a checkout (it gets the path as `$TASKS_ROOT`). Task IDs on the
            board are terminal links: to my.taskBoard.linkBase when the file matches
            the checkout's upstream branch, otherwise to the local file. Needs
            my.taskBoard.script and my.flakePath
          '';
          rows = lib.mkOption {
            type = lib.types.ints.positive;
            default = 4;
            description = "Lines per board column, including the `+k more` line when tasks are cut.";
          };
          columns = lib.mkOption {
            type = lib.types.listOf (
              lib.types.enum [
                "progress"
                "todo"
                "attention"
              ]
            );
            default = [
              "progress"
              "todo"
              "attention"
            ];
            description = ''
              Board columns, left to right: `progress` (ACTIVE tasks), `todo` (OPEN
              and REVIEW tasks) and `attention` (open tasks whose review is overdue
              or due within 2 days; they leave the other two columns).
            '';
          };
        };

        torrentVpn = {
          enable = lib.mkEnableOption "qBittorrent only through the Proton VPN tunnel, on Proton's forwarded port";
        };

        streaming = {
          sunshine.enable = lib.mkEnableOption "the Sunshine game-streaming setup (wrapper, output helper, route)";
          moonshine.enable = lib.mkEnableOption "the Moonshine game-streaming server";
        };

        user = {
          name = lib.mkOption {
            type = lib.types.strMatching "[a-z_][a-z0-9_-]*";
            description = "The main desktop user's login name.";
          };
          description = lib.mkOption {
            type = lib.types.str;
            default = config.my.user.name;
            defaultText = lib.literalExpression "config.my.user.name";
            description = "The main user's full name.";
          };
        };

        network = {
          domain = lib.mkOption {
            type = lib.types.strMatching "([a-z0-9-]+\\.)+[a-z]+";
            example = "myhost.example.com";
            description = "Public domain; services are served on its subdomains.";
          };
          lanInterface = lib.mkOption {
            # Linux interface names are at most 15 characters.
            type = lib.types.strMatching "[A-Za-z0-9._-]{1,15}";
            example = "br0";
            description = "LAN interface whose firewall allows local services (SSH, media, sync).";
          };
          ovhDns.enable = lib.mkEnableOption ''
            certificates for my.network.domain and its subdomains through OVH's DNS
            API. Needs the ovh_* secrets in my.secretsFile; off, Caddy uses its
            default ACME challenges, which cannot issue the wildcard certificate'';
          lanAddress = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "192.168.1.30";
            description = "The machine's LAN address, for web UIs that check the origin they are opened from (Sunshine); null allows only the domain.";
          };
        };

        externalDrives = {
          names = lib.mkOption {
            type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9._-]+");
            default = [ ];
            example = [
              "media"
              "backup"
            ];
            description = ''
              Drives mounted at /srv/external/<name> (by the host's storage config),
              shared read-only with Jellyfin and Nextcloud and read-write with
              qBittorrent when those services are on.
            '';
          };
          hiddenFromNextcloud = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "media/lost+found" ];
            description = ''
              Folders on those drives, as <name>/<path>, that Nextcloud's www-data
              cannot read. One unreadable folder makes Nextcloud mark the whole
              "External drives" storage unavailable, so each is covered with an empty
              read-only folder in the container; each must exist on its drive.
            '';
          };
        };

        dashboard.settingsFile = lib.mkOption {
          type = lib.types.path;
          default = ../home/dashboard-settings.json;
          defaultText = lib.literalExpression "../home/dashboard-settings.json";
          example = lib.literalExpression "../../../home/dashboard-settings.json";
          description = ''
            The dashboard's cards and actions (JSON). In it, @host@ and @Host@ become
            the host name (as is and capitalised), @domain@ my.network.domain and
            @domainSuffix@ that domain without its first label.
          '';
        };

        xremap.config = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = lib.literalExpression "../../../home/xremap/config.yml";
          description = ''
            The user's xremap keymap (~/.config/xremap/config.yml). Null deploys the
            base's home/xremap/config.yml, with its launcher paths under the user's
            home directory. The keymap applies where the xremap aspect runs.
          '';
        };

        windowsReboot = {
          script = lib.mkOption {
            type = lib.types.path;
            default = ./dashboard-control/reboot_windows.py;
            defaultText = lib.literalExpression "./dashboard-control/reboot_windows.py";
            example = lib.literalExpression "../../../dashboard-control/reboot_windows.py";
            description = ''
              Python script behind the dashboard's "reboot into Windows" button
              (dashboard-reboot-windows.service, run as root). It must check the
              machine's own root and ESP filesystem UUIDs before selecting the
              Windows GRUB entry; the default is a template whose placeholder UUIDs
              make it refuse to run. Copy it, set the UUIDs, and point this at the copy.
            '';
          };
          userScript = lib.mkOption {
            type = lib.types.path;
            default = ../home/reboot-windows.py;
            defaultText = lib.literalExpression "../home/reboot-windows.py";
            example = lib.literalExpression "../../../home/reboot-windows.py";
            description = ''
              The user's ~/.local/bin/reboot-windows (EFI BootNext, then reboot). The
              default is a template whose placeholder Windows ESP PARTUUID makes it
              refuse to run; copy it with the machine's PARTUUID and point this at
              the copy.
            '';
          };
        };

        spotify.desktopApp.enable = lib.mkEnableOption ''
          the official Spotify desktop app, themed by Noctalia through Spicetify
          (Spotifast is installed either way)
        '';

        ambilight = {
          enable = lib.mkEnableOption "HyperHDR ambient lighting from screen capture";
          musicSink = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "alsa_output.usb-iFi__by_AMR__iFi__by_AMR__HD_USB_Audio_0003-00.analog-stereo";
            description = "PipeWire sink whose output HyperHDR captures for music effects (`pw-cli ls Node`).";
          };
          wledUrl = lib.mkOption {
            type = lib.types.nullOr urlType;
            default = null;
            example = "http://192.168.1.50";
            description = "WLED controller the dashboard's ambilight buttons switch.";
          };
        };

        headphoneEq = {
          enable = lib.mkEnableOption "a parametric headphone EQ sink (PipeWire filter-chain), switched on with `headphone-eq on`";
          name = lib.mkOption {
            type = lib.types.str;
            default = "FiiO FT1";
            description = "Preset name: the EQ panel's choice, and the sink is \"<name> EQ\".";
          };
          target = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "alsa_output.usb-iFi__by_AMR__iFi__by_AMR__HD_USB_Audio_0003-00.analog-stereo";
            description = "PipeWire sink the equalised audio plays into (`pw-cli ls Node`).";
          };
          preamp = lib.mkOption {
            type = lib.types.float;
            default = -4.7;
            description = "Preamp gain in dB, applied before the bands.";
          };
          bands = lib.mkOption {
            type = lib.types.listOf (
              lib.types.submodule {
                options = {
                  type = lib.mkOption {
                    type = lib.types.enum [
                      "peak"
                      "lowshelf"
                      "highshelf"
                    ];
                    description = "Filter shape.";
                  };
                  freq = lib.mkOption {
                    type = lib.types.number;
                    description = "Centre or corner frequency in Hz.";
                  };
                  gain = lib.mkOption {
                    type = lib.types.number;
                    description = "Gain in dB.";
                  };
                  q = lib.mkOption {
                    type = lib.types.number;
                    description = "Quality factor (bandwidth).";
                  };
                };
              }
            );
            # FiiO FT1, "Super review" profile (SoundSource Headphone EQ on the Mac).
            default = [
              {
                type = "peak";
                freq = 63;
                gain = 1.4;
                q = 3.18;
              }
              {
                type = "lowshelf";
                freq = 105;
                gain = -3.4;
                q = 0.7;
              }
              {
                type = "peak";
                freq = 151;
                gain = -3.0;
                q = 1.51;
              }
              {
                type = "peak";
                freq = 465;
                gain = 1.4;
                q = 1.66;
              }
              {
                type = "peak";
                freq = 1625;
                gain = -2.0;
                q = 1.01;
              }
              {
                type = "peak";
                freq = 3697;
                gain = 5.1;
                q = 3.64;
              }
              {
                type = "peak";
                freq = 5160;
                gain = -5.6;
                q = 5.03;
              }
              {
                type = "peak";
                freq = 6011;
                gain = 4.8;
                q = 3.01;
              }
              {
                type = "peak";
                freq = 9024;
                gain = 5.0;
                q = 2.13;
              }
              {
                type = "highshelf";
                freq = 10000;
                gain = -6.6;
                q = 0.7;
              }
            ];
            description = "Parametric EQ bands (frequency in Hz, gain in dB).";
          };
        };

        yubikey = {
          enable = lib.mkEnableOption "YubiKey (pam_u2f) touch for sudo, with a touch notification";
          sound = lib.mkOption {
            type = lib.types.str;
            default = "${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/dialog-information.oga";
            defaultText = lib.literalExpression ''"''${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/dialog-information.oga"'';
            example = lib.literalExpression ''"''${pkgs.kdePackages.oxygen-sounds}/share/sounds/oxygen/stereo/dialog-question.ogg"'';
            description = "Sound played (with pw-play) while the YubiKey waits for a touch.";
          };
          lockOnRemoval = lib.mkEnableOption ''
            locking every session (`loginctl lock-sessions`) when a YubiKey is unplugged and
            none is back within two seconds. Password and fingerprint still unlock'';
        };

        sequoiaWallpaper = {
          enable = lib.mkEnableOption ''
            the live `sequoia:` wallpaper in Noctalia (the macOS Sequoia scene, animated on
            the lock screen, and in the greeter when my.liquidGlass is on too). Needs the
            scene file in ~/.local/share/sequoia, which is not in the repository'';
        };

        shaderWallpaper = {
          enable = lib.mkEnableOption ''
            the live `shader:` wallpaper in Noctalia (Shadertoy-style GLSL shaders, pause
            behind windows, the noctalia-shader-thumbnail tool). Needs my.sequoiaWallpaper,
            whose patch it is stacked on'';
          kdeLibrary = lib.mkEnableOption ''
            KDE Shader Wallpaper's shader library (pinned) in share/noctalia/shaders/kde, for
            the shader wallpaper and its picker plugin'';
        };

        liquidGlass = {
          enable = lib.mkEnableOption ''
            liquid glass: Umbriel's glass under windows, Noctalia's panels and the
            terminals' rim (home/umbriel/glass.toml), and the glass under the lock
            screen and greeter login boxes (Noctalia patches). Off, they keep plain blur'';
          tuner = lib.mkOption {
            type = lib.types.nullOr lib.types.package;
            default = null;
            example = lib.literalExpression "inputs.glass-tuner.packages.\${pkgs.stdenv.hostPlatform.system}.default";
            description = "Live sliders for the glass (the glass-tuner app), installed while my.liquidGlass is on; null installs none.";
          };
        };

        strata.override = lib.mkOption {
          type = lib.types.functionTo lib.types.package;
          default = lib.id;
          defaultText = lib.literalExpression "lib.id";
          example = lib.literalExpression "strata: strata.overrideAttrs (old: { patches = old.patches ++ [ ./extra.patch ]; })";
          description = ''
            Function applied to the patched, unwrapped Strata package before the
            launcher wrapper, for a host's own patches or helpers; the default
            leaves it unchanged.'';
        };

        vmwgfxDmabufFix = lib.mkEnableOption ''
          a wlroots patch for VMware guests (vmwgfx), applied to Umbriel and the
          Noctalia greeter's compositor: vmwgfx imports a client's DMA-BUF but fails
          to close the handle, and stock wlroots then rejects every GPU-rendered
          buffer, so the greeter and apps die with "importing the supplied dmabufs
          failed"'';

        modes = {
          enable = lib.mkEnableOption ''
            desktop modes (`erebor-modes`, SYS-122): while the power-saver profile is
            on, liquid glass, animated wallpapers, the audio visualizer, the ambilight
            and display brightness (and optionally the GPU power limit) are turned
            down, and put back afterwards'';
          reduceTransparency = {
            opacity = lib.mkOption {
              type = lib.types.numbers.between 0 1;
              default = 0.9;
              description = ''
                Lowest opacity of apps (Ghostty, Monstar, Vicinae, Zed, Strata, Zen,
                Darkly) and Noctalia's dock, OSD and notifications while Reduce
                transparency is on (a Noctalia toggle); glass and blur stay, Noctalia's
                panels go from "glass" to "soft" transparency.'';
            };
            barOpacity = lib.mkOption {
              type = lib.types.numbers.between 0 1;
              default = 0.75;
              description = "Lowest opacity of Noctalia's bars and their capsules while Reduce transparency is on.";
            };
          };
          powerSaver = {
            brightnessCap = lib.mkOption {
              type = lib.types.ints.between 0 100;
              default = 10;
              description = "Highest DDC brightness (percent) while power-saver is on; lower values are kept.";
            };
            brightnessConnectors = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "DP-1" ];
              description = "Connectors whose DDC brightness power-saver caps; none leaves brightness alone.";
            };
            ambilightBrightness = lib.mkOption {
              type = lib.types.ints.between 0 255;
              default = 64;
              description = "WLED brightness (0-255) while power-saver is on; never turns the strips on.";
            };
            gpuPowerLimit = lib.mkOption {
              type = lib.types.nullOr lib.types.ints.positive;
              default = null;
              example = 200;
              description = "NVIDIA power limit in watts while power-saver is on (a root unit); null leaves it.";
            };
          };
        };

        macApproval = {
          enable = lib.mkEnableOption "sudo and polkit approval through a forwarded Mac SSH agent";
          addresses = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [
              "100.64.0.2"
              "192.168.1.20"
            ];
            description = "The Mac's Tailscale and LAN addresses; sshd drops its sessions when it sleeps.";
          };
        };

        phoneApproval = {
          enable = lib.mkEnableOption ''
            sudo approval from the phone: a one-time link goes to the phone through
            KDE Connect, and a passkey on the phone approves it. The YubiKey and the
            password still work; enroll the phone with `phone-approval-enroll`'';
          device = lib.mkOption {
            type = lib.types.nullOr (lib.types.strMatching "[A-Za-z0-9_]+");
            default = null;
            example = "0123456789abcdef0123456789abcdef";
            description = "KDE Connect ID of the phone (`kdeconnect-cli -l`).";
          };
          timeout = lib.mkOption {
            type = lib.types.ints.between 5 120;
            default = 30;
            description = "Seconds sudo waits for the phone before trying the next method.";
          };
        };

        nanokvm = {
          enable = lib.mkEnableOption "NanoKVM wake and outlet readings in the dashboard";
          url = lib.mkOption {
            type = lib.types.nullOr urlType;
            default = null;
            example = "https://nanokvm.example.ts.net:8443";
            description = "Base URL of the wake helper installed on the NanoKVM.";
          };
        };
      };

      # Each message names the my.* setting to change in modules/hosts/<name>.
      config.assertions = [
        {
          assertion = cfg.taskBoard.enable -> cfg.taskBoard.script != null && cfg.flakePath != null;
          message = "my.taskBoard.enable needs my.taskBoard.script (the task script) and my.flakePath (the checkout it reads).";
        }
        {
          assertion = cfg.shellTasks.enable -> cfg.taskBoard.script != null && cfg.flakePath != null;
          message = "my.shellTasks.enable needs my.taskBoard.script (the task script) and my.flakePath (the checkout it reads).";
        }
        {
          assertion = cfg.network.ovhDns.enable -> cfg.secretsFile != null;
          message = "my.network.ovhDns.enable needs my.secretsFile: the host's sops file with the ovh_* secrets.";
        }
        {
          assertion = cfg.headphoneEq.enable -> cfg.headphoneEq.target != null;
          message = "my.headphoneEq.enable needs my.headphoneEq.target: the PipeWire sink the EQ plays into (`pw-cli ls Node`).";
        }
        {
          assertion = cfg.ambilight.enable -> cfg.ambilight.musicSink != null;
          message = "my.ambilight.enable needs my.ambilight.musicSink: the PipeWire sink HyperHDR captures (`pw-cli ls Node`).";
        }
        {
          assertion = cfg.macApproval.enable -> cfg.macApproval.addresses != [ ];
          message = "my.macApproval.enable needs my.macApproval.addresses: the Mac's Tailscale and LAN addresses.";
        }
        {
          assertion = cfg.phoneApproval.enable -> cfg.phoneApproval.device != null;
          message = "my.phoneApproval.enable needs my.phoneApproval.device: the phone's KDE Connect ID (`kdeconnect-cli -l`).";
        }
        {
          assertion = cfg.nanokvm.enable -> cfg.nanokvm.url != null;
          message = "my.nanokvm.enable needs my.nanokvm.url: the base URL of the NanoKVM wake helper.";
        }
      ]
      ++ map (clash: {
        assertion = false;
        message = "my.services: ${clash} as their loopback port; give each a different my.services.<name>.port.";
      }) (clashes "port")
      ++ map (clash: {
        assertion = false;
        message = "my.services: ${clash} as their LAN port; give each a different my.services.<name>.lanPort.";
      }) (clashes "lanPort")
      ++ map (clash: {
        assertion = false;
        message = "my.services: ${clash} as their public name; change my.services.<name>.publicName.";
      }) (clashes "publicName");
    };
}

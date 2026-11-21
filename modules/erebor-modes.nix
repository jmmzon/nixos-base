# Desktop modes (SYS-122): `erebor-modes` turns items down while a mode is
# active and puts them back afterwards. The only mode today is power-saver,
# active while power-profiles-daemon's profile is "power-saver".
#
# - Home Manager: the `erebor-modes` command (erebor-modes/erebor_modes.py) and
#   its manifest, generated here from the my.* toggles so the engine, the
#   notification and the UI surfaces read one list of items. Noctalia's
#   `power_profile_changed` hook runs `erebor-modes-hook`; its `started` hook
#   runs `erebor-session-started` (theme opacity, then the modes).
# - NixOS: the NVIDIA power limit follows the profile from a root unit
#   (nvidia-smi needs root), when my.modes.powerSaver.gpuPowerLimit is set.
#
# State for the surfaces (Noctalia plugins, glass tuner, dashboard):
# ~/.local/state/erebor-modes/state.json (`erebor-modes status --json`).
{ ... }:
{
  flake.modules.homeManager.erebor-modes =
    {
      config,
      osConfig,
      lib,
      pkgs,
      ...
    }:
    let
      my = osConfig.my;
      cfg = my.modes;
      ps = cfg.powerSaver;
      stateDir = "${config.xdg.stateHome}/erebor-modes";
      hdrToggle = "${config.home.homeDirectory}/.local/bin/umbriel-hdr-toggle";

      # Umbriel include (home/umbriel/config.toml lists it before noctalia.toml,
      # which Noctalia's theme hook keeps last; SYS-124): present only
      # while the glass item is applied. "off" drops the backdrop glass of every
      # layer and window and the terminals' rim; plain blur stays.
      glassOff = ''
        # Written by erebor-modes while the power-saver mode is on; removed after.
        [[layer_rule]]
        match.namespace = ".*"
        backdrop_effect = "off"

        [[window_rule]]
        backdrop_effect = "off"
        border_effect = "off"
      '';

      powerSaverItems =
        lib.optional my.liquidGlass.enable {
          id = "glass";
          label = "Liquid glass off";
          glyph = "droplet-off";
          handler = "file";
          params = {
            path = "${stateDir}/umbriel.toml";
            content = glassOff;
          };
        }
        ++ lib.optional my.shaderWallpaper.enable {
          id = "wallpaper-shader";
          label = "Shader wallpaper paused";
          glyph = "player-pause";
          handler = "noctalia-setting";
          params = {
            key = "wallpaper.shader.paused";
            value = true;
          };
        }
        ++ lib.optional my.sequoiaWallpaper.enable {
          id = "wallpaper-sequoia";
          label = "Sequoia wallpaper still";
          glyph = "player-pause";
          handler = "noctalia-setting";
          params = {
            key = "wallpaper.sequoia.desktop_motion";
            value = "still";
          };
        }
        ++ [
          {
            id = "wallpaper-engine";
            label = "Wallpaper Engine paused";
            glyph = "player-pause";
            handler = "plugin-pause";
            params = {
              entry = "janzon/wallpaper-engine:service";
              unit = "noctalia-wallpaper-engine";
            };
          }
        ]
        ++ lib.optional (my.ambilight.enable && my.ambilight.wledUrl != null) {
          id = "ambilight";
          label = "Ambilight dimmed";
          glyph = "bulb";
          handler = "wled-brightness";
          params = {
            url = my.ambilight.wledUrl;
            brightness = ps.ambilightBrightness;
          };
        }
        ++ lib.optional (ps.brightnessConnectors != [ ]) {
          id = "brightness";
          label = "Display brightness ≤ ${toString ps.brightnessCap}";
          glyph = "brightness-down";
          handler = "ddc-cap";
          params = {
            connectors = ps.brightnessConnectors;
            cap = ps.brightnessCap;
          };
        }
        ++ [
          {
            id = "visualizer";
            label = "Audio visualizer hidden";
            glyph = "wave-sine";
            handler = "noctalia-list-remove";
            params = {
              key = "bar.default.start";
              entry = "audio_visualizer";
            };
          }
        ]
        ++ lib.optional (ps.gpuPowerLimit != null) {
          id = "gpu";
          label = "GPU power limit ${toString ps.gpuPowerLimit} W";
          glyph = "cpu";
          handler = "report";
          params.read = [
            "nvidia-smi"
            "--query-gpu=power.limit"
            "--format=csv,noheader"
          ];
        }
        # Offered, not applied: the notification has a button for it.
        ++ [
          {
            id = "hdr";
            label = "HDR off";
            glyph = "hdr";
            offer = true;
            action = "Turn HDR off";
            handler = "command";
            params = {
              read = [
                hdrToggle
                "status"
              ];
              "when" = "on";
              apply = [ hdrToggle ];
              applied = "off";
              restore = [ hdrToggle ];
            };
          }
        ];

      # Reduce transparency: erebor-theme-opacity raises every opacity while its
      # flag file exists (modules/home/theme-opacity.nix); this item holds the flag.
      transparency = {
        id = "transparency";
        label = "Transparency reduced";
        glyph = "contrast";
        handler = "file";
        params = {
          path = "${config.xdg.stateHome}/erebor-theme-opacity/reduce";
          content = "on\n";
        };
        after = [ "erebor-theme-opacity" ];
      };

      manifest = pkgs.writeText "erebor-modes.json" (
        builtins.toJSON {
          modes = [
            {
              id = "power-saver";
              label = "Power saver";
              icon = "battery-profile-powersave";
              glyph = "leaf";
              "when".power_profile = "power-saver";
              leave = {
                label = "Switch to balanced";
                command = [
                  "powerprofilesctl"
                  "set"
                  "balanced"
                ];
              };
              # Offered in power-saver (notification and mode panel); off again when it ends.
              items = powerSaverItems ++ [
                (
                  transparency
                  // {
                    offer = true;
                    action = "Reduce transparency too";
                  }
                )
              ];
            }
            {
              id = "reduce-transparency";
              label = "Reduce transparency";
              kind = "toggle";
              notify = false;
              icon = "preferences-desktop-theme";
              glyph = "contrast";
              "when".toggle = "reduce-transparency";
              leave = {
                label = "Turn off";
                command = [
                  "erebor-modes"
                  "toggle"
                  "reduce-transparency"
                  "off"
                ];
              };
              items = [ transparency ];
            }
          ];
        }
      );

      erebor-modes = pkgs.writeShellApplication {
        name = "erebor-modes";
        runtimeInputs = with pkgs; [
          python3
          ddcutil
          power-profiles-daemon
          libnotify
          systemd
        ];
        text = ''
          # Noctalia, Umbriel and the user's helpers, as in a hook's environment;
          # nvidia-smi from the system.
          export PATH="$PATH:/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin"
          export EREBOR_MODES_MANIFEST=${manifest}
          export EREBOR_MODES_STATE_DIR=${lib.escapeShellArg stateDir}
          exec python3 ${./erebor-modes/erebor_modes.py} "$@"
        '';
      };

      # Noctalia hooks take a command path, so the hooks get argument-free names.
      hook = pkgs.writeShellScriptBin "erebor-modes-hook" ''
        exec ${erebor-modes}/bin/erebor-modes sync
      '';
      started = pkgs.writeShellScriptBin "erebor-session-started" ''
        # Noctalia's `started` hook: everything that follows a shell setting.
        if command -v erebor-theme-opacity >/dev/null; then erebor-theme-opacity || true; fi
        exec ${erebor-modes}/bin/erebor-modes sync
      '';
    in
    lib.mkIf cfg.enable {
      home.packages = [
        erebor-modes
        hook
        started
      ];
    };

  flake.modules.nixos.erebor-modes =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      limit = config.my.modes.powerSaver.gpuPowerLimit;
      nvidia = lib.elem "nvidia" config.services.xserver.videoDrivers;
    in
    lib.mkIf (config.my.modes.enable && limit != null && nvidia) {
      # The power limit is reset by the driver on boot, so nothing to undo here.
      systemd.services.erebor-gpu-power-limit = {
        description = "NVIDIA power limit follows the power profile (erebor-modes)";
        wantedBy = [ "multi-user.target" ];
        after = [ "power-profiles-daemon.service" ];
        wants = [ "power-profiles-daemon.service" ];
        path = [
          config.hardware.nvidia.package.bin
          pkgs.power-profiles-daemon
          pkgs.glib
          pkgs.gnugrep
        ];
        script = ''
          apply() {
            if [ "$(powerprofilesctl get)" = power-saver ]; then
              want=${toString limit}
            else
              want=$(nvidia-smi --query-gpu=power.default_limit --format=csv,noheader,nounits | head -n1)
            fi
            want=''${want%.*}
            have=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits | head -n1)
            [ "''${have%.*}" = "$want" ] || nvidia-smi -pl "$want"
          }
          apply
          gdbus monitor --system --dest org.freedesktop.UPower.PowerProfiles \
            --object-path /org/freedesktop/UPower/PowerProfiles |
            while read -r line; do
              case "$line" in *ActiveProfile*) apply ;; esac
            done
        '';
        serviceConfig = {
          Restart = "always";
          RestartSec = 5;
        };
      };
    };
}

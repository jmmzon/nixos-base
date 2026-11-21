# Noctalia: the desktop shell, its greeter and lyrics daemon, and the Home
# Manager files it reads (home/noctalia: config.toml, plugins, bar scripts).
{ inputs, ... }:
{
  flake.modules.nixos.noctalia =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      user = config.my.user.name;
      noctaliaPython = pkgs.callPackage ../packages/noctalia-python.nix { };
      inherit (config.programs.noctalia) patches;
      greeterPatches = config.programs.noctalia.greeterPatches;
    in
    {
      imports = [
        inputs.noctalia-greeter.nixosModules.default
        inputs.noctalia.nixosModules.default
        {
          # Features that patch Noctalia (lockscreen-yubikey, sequoia-wallpaper, lockscreen-glass) add
          # their patch here; they apply in list order to the flake input's package.
          options.programs.noctalia.patches = lib.mkOption {
            type = lib.types.listOf lib.types.path;
            default = [ ];
            internal = true;
            description = "Patches applied, in order, to Noctalia from the flake input.";
          };
          # Features that patch the greeter (greeter-glass, plymouth-greeter-handoff) add their patch here.
          options.programs.noctalia.greeterPatches = lib.mkOption {
            type = lib.types.listOf lib.types.path;
            default = [ ];
            internal = true;
            description = "Patches applied, in order, to the Noctalia greeter from the flake input.";
          };
        }
      ];

      systemd.user.services.noctalia-lyrics = {
        description = "Noctalia Spotify lyrics daemon";
        after = [
          "graphical-session.target"
          "noctalia.service"
        ];
        partOf = [ "graphical-session.target" ];
        wantedBy = [ "graphical-session.target" ];
        path = [ pkgs.playerctl ];
        serviceConfig = {
          ExecStart = "${noctaliaPython}/bin/python3 -B /home/${user}/.local/state/noctalia/plugins/materialized/community/spotify-lyrics/spotify_lyrics_daemon.py";
          Restart = "on-failure";
          RestartSec = 5;
        };
      };

      # A graphical greeter does not need Type=idle's console-output delay.
      systemd.services.greetd.serviceConfig.Type = lib.mkForce "exec";

      services.displayManager.noctalia-greeter = {
        enable = true;
        package = lib.mkIf (greeterPatches != [ ] || config.my.vmwgfxDmabufFix) (
          let
            base = inputs.noctalia-greeter.packages.${pkgs.stdenv.hostPlatform.system}.default;
            patched =
              if greeterPatches == [ ] then
                base
              else
                base.overrideAttrs (old: {
                  patches = (old.patches or [ ]) ++ greeterPatches;
                  buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.libdrm ];
                });
          in
          if config.my.vmwgfxDmabufFix then import ./_wlroots-vmwgfx.nix pkgs patched else patched
        );
        passwordless-sync-users = [ "${user}" ];
        settings = {
          appearance.scheme = "Synced";
          user.default = "${user}";
          session.default = "umbriel";
          idle.timeout = 60;
        };
      };

      programs.noctalia = {
        enable = true;
        systemd.enable = true;
        recommendedServices.enable = true;
        package = lib.mkIf (patches != [ ]) (
          inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ patches;
          })
        );
      };

      # Noctalia updates this policy with the current palette for Helium.
      # Preserve the rendered color across rebuilds; this must stay a writable file.
      systemd.tmpfiles.settings."10-noctalia-chromium"."/etc/chromium/policies/managed/noctalia-color.json".f =
        {
          user = "${user}";
          group = "users";
          mode = "0644";
          argument = "{}";
        };
    };

  flake.modules.homeManager.noctalia =
    {
      config,
      osConfig,
      pkgs,
      ...
    }:
    let
      liveFile = import ./_live-file.nix { inherit config osConfig; };
      # Plugin scripts have no `require`: a line `-- @include <name>` is
      # replaced by home/noctalia/plugins/_shared/<name with _>.luau (e.g. the
      # erebor-modes card, SYS-122), so plugins share one copy of it.
      withShared =
        name:
        pkgs.runCommand "noctalia-plugin-${name}" { } ''
          cp -r ${../home/noctalia/plugins/${name}} $out
          chmod -R u+w $out
          for f in $out/*.luau; do
            ${pkgs.gawk}/bin/awk -v shared=${../home/noctalia/plugins/_shared} '
              /^-- @include [a-z-]+$/ {
                file = shared "/" gensub(/-/, "_", "g", $3) ".luau"
                while ((getline line < file) > 0) print line
                if (close(file) != 0) { print "missing " file > "/dev/stderr"; exit 1 }
                next
              }
              { print }
            ' "$f" > "$f.tmp"
            mv "$f.tmp" "$f"
          done
        '';
    in
    {
      # Live: a link into the checkout (my.flakePath); the settings window's
      # ~/.local/state/noctalia/settings.toml still overrides it.
      xdg.configFile."noctalia/config.toml".source = liveFile "home/noctalia/config.toml";
      # Local plugins in the data dir outrank every plugin source.
      xdg.dataFile."noctalia/plugins/wallpaper-engine".source = withShared "wallpaper-engine";
      xdg.dataFile."noctalia/plugins/toggles".source = withShared "toggles";
      # Picker for the live "sequoia:" and "shader:" wallpapers (needs the shader wallpaper patch).
      xdg.dataFile."noctalia/plugins/live-wallpaper".source = withShared "live-wallpaper";
      home.file.".local/bin/noctalia-bar-focus" = {
        source = pkgs.writeShellScript "noctalia-bar-focus" ''
          set -euo pipefail

          direction="''${1:-}"
          case "$direction" in
            left|right) ;;
            *) exit 2 ;;
          esac

          case ":''${XDG_CURRENT_DESKTOP,,}:" in
            *:hyprland:*) exec hyprctl dispatch "hl.dsp.layout('focus ''${direction:0:1}')" ;;
            *) exec umbriel msg "window-focus-$direction" ;;
          esac
        '';
        executable = true;
      };
      home.file.".local/bin/noctalia-bar-autohide" = {
        source = ../home/noctalia/bar-autohide;
        executable = true;
      };
    };
}

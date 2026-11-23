# Umbriel, the primary compositor: the system session and its Home Manager
# configuration (home/umbriel/config.toml) with the helper scripts it binds.
{ inputs, ... }:
let
  # Umbriel from the fork's `erebor` branch (flake input `umbriel`): upstream
  # plus the local commits (backdrop effect kind, touchpad gestures, scroll
  # accel curve, strip scroll clamp, overview scroll handoff, umbriel_glass_v1
  # regions, effect params, backdrop corners, glass light). Rebase that branch
  # on upstream to update. Both the system and Home Manager install it.
  patched = pkgs: inputs.umbriel.packages.${pkgs.stdenv.hostPlatform.system}.default;
  # my.vmwgfxDmabufFix (VMware guests): also rebuild against patched wlroots.
  forHost =
    pkgs: my:
    if my.vmwgfxDmabufFix then import ./_wlroots-vmwgfx.nix pkgs (patched pkgs) else patched pkgs;
in
{
  flake.modules.nixos.umbriel =
    { config, pkgs, ... }:
    {
      imports = [ inputs.umbriel.nixosModules.default ];
      programs.umbriel = {
        enable = true;
        package = forHost pkgs config.my;
      };
    };

  flake.modules.homeManager.umbriel =
    {
      config,
      osConfig,
      lib,
      pkgs,
      ...
    }:
    let
      liveFile = import ./_live-file.nix { inherit config osConfig; };
    in
    {
      imports = [ inputs.umbriel.homeModules.default ];
      programs.umbriel = {
        enable = true;
        package = forHost pkgs osConfig.my;
        # Live: a link into the checkout (my.flakePath), which Umbriel watches
        # through the symlinks, so a saved edit applies without a rebuild.
        settings = liveFile "home/umbriel/config.toml";
      };
      # Liquid glass, an optional include of config.toml: without this link
      # Umbriel ignores it and windows and panels keep plain blur. Also live.
      xdg.configFile."umbriel/glass.toml" = lib.mkIf osConfig.my.liquidGlass.enable {
        source = liveFile "home/umbriel/glass.toml";
      };
      # Light mode's overrides of glass.toml's params: erebor-theme-opacity
      # (modules/home/theme-opacity.nix) links this into the include list while
      # Noctalia is in light mode. Also live.
      xdg.configFile."umbriel/glass-light.toml" = lib.mkIf osConfig.my.liquidGlass.enable {
        source = liveFile "home/umbriel/glass-light.toml";
      };
      # The store copy of glass.toml names its shaders relative to itself.
      xdg.configFile."umbriel/effects" =
        lib.mkIf (osConfig.my.liquidGlass.enable && osConfig.my.flakePath == null)
          {
            source = ../home/umbriel/effects;
          };
      # Umbriel's overview: for the edge swipe below and Noctalia's bar and
      # hot corner.
      home.packages = [
        (pkgs.writeShellScriptBin "desktop-overview-toggle" ''
          exec umbriel msg overview-toggle
        '')
      ];
      # Edge swipes, which libinput does not report: reads the touchpads' raw
      # touches beside libinput (no grab; the main user is in the input group).
      systemd.user.services.edge-swipe =
        let
          edgeSwipe = pkgs.writers.writePython3Bin "edge-swipe" {
            libraries = [ pkgs.python3Packages.evdev ];
            flakeIgnore = [
              "E501"
              "W503"
            ];
          } (builtins.readFile ../home/umbriel/edge-swipe.py);
        in
        {
          Unit = {
            Description = "Touchpad edge swipes";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = lib.escapeShellArgs [
              (lib.getExe edgeSwipe)
              "top=desktop-overview-toggle"
              "right=noctalia msg panel-toggle control-center notifications"
            ];
            Environment = [ "PATH=${config.home.profileDirectory}/bin:/run/current-system/sw/bin" ];
            Restart = "on-failure";
            RestartSec = 2;
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };
      # Keeps the chat workspace for communicators: another app that opens on
      # it moves to the workspace the user came from. The id pattern matches
      # the chat window rule in home/umbriel/config.toml.
      systemd.user.services.chat-workspace-guard =
        let
          guard = pkgs.writeShellApplication {
            name = "umbriel-workspace-guard";
            runtimeInputs = [ pkgs.jq ];
            text = builtins.readFile ../home/umbriel/workspace-guard;
          };
        in
        {
          Unit = {
            Description = "Move other apps off the chat workspace";
            # Umbriel only (umbriel IPC).
            ConditionEnvironment = "XDG_CURRENT_DESKTOP=umbriel";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = lib.escapeShellArgs [
              (lib.getExe guard)
              "chat"
              # [.] rather than \. : systemd warns about backslashes in ExecStart.
              "^(discord|com[.]rtosta[.]zapzap|signal)$"
            ];
            Environment = [ "PATH=${config.home.profileDirectory}/bin:/run/current-system/sw/bin" ];
            Restart = "always";
            RestartSec = 2;
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };
      home.file.".local/bin/umbriel-scratchpad-hint" = {
        source = pkgs.replaceVars ../home/umbriel/scratchpad-hint {
          inherit (pkgs) libnotify systemd;
        };
        executable = true;
      };
      home.file.".local/bin/umbriel-scratchpad-navigate" = {
        source = ../home/umbriel/scratchpad-navigate;
        executable = true;
      };
      home.file.".local/bin/umbriel-caps-q" = {
        source = ../home/umbriel/caps-q-window;
        executable = true;
      };
      home.file.".local/bin/umbriel-focus-or-launch" = {
        source = ../home/umbriel/focus-or-launch;
        executable = true;
      };
      home.file.".local/bin/umbriel-screenshot-window" = {
        source = ../home/umbriel/screenshot-window;
        executable = true;
      };
      home.file.".local/bin/umbriel-monstar-tab" = {
        source = ../home/umbriel/monstar-tab;
        executable = true;
      };
      home.file.".local/bin/umbriel-hdr-toggle" = {
        source = pkgs.writeShellScript "umbriel-hdr-toggle" ''
          set -euo pipefail

          output="DP-1"
          hdr_active="$(umbriel outputs --json | jq -r --arg name "$output" '.[] | select(.name == $name) | .hdr_active')"
          # `status` prints on/off for the Noctalia HDR bar button.
          if [ "''${1:-toggle}" = status ]; then
            case "$hdr_active" in
              true) echo on ;;
              false) echo off ;;
              *) exit 1 ;;
            esac
            exit 0
          fi
          case "$hdr_active" in
            true) hdr="off" ;;
            false) hdr="on" ;;
            *) exit 1 ;;
          esac

          runtime_dir="''${XDG_RUNTIME_DIR:?}"
          display="''${WAYLAND_DISPLAY:-wayland-0}"
          display="''${display//[^a-zA-Z0-9_.-]/_}"
          profile="$runtime_dir/umbriel-hdr-$display.toml"
          temporary="$profile.tmp.$$"
          umask 077
          trap 'rm -f "$temporary"' EXIT
          cat > "$temporary" <<EOF
          [include]
          files = ["$HOME/.config/umbriel/config.toml"]

          [output."$output"]
          hdr = "$hdr"
          EOF
          mv "$temporary" "$profile"
          trap - EXIT
          exec umbriel config-replace "$profile"
        '';
        executable = true;
      };
    };
}

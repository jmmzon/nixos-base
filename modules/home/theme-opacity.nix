# Lower opacity in light mode, and raise it while "Reduce transparency" is on.
# Noctalia's `started` and `theme_mode_changed` hooks (home/noctalia/config.toml)
# run `erebor-theme-opacity`, which
# - links the app configs that carry home/appearance.nix's appOpacity for that
#   mode (Ghostty's include, Monstar's config, Vicinae's nix.json, Noctalia's
#   Zed and Strata templates, Zen's CSS) from ~/.local/state/erebor-theme-opacity,
#   and Strata's rendered theme, then makes the running apps reload
#   (Ghostty: SIGUSR2, Monstar: SIGUSR1; Vicinae watches its files; Zed and
#   Strata through `noctalia msg templates-apply`; Zen at its next start);
# - picks the liquid glass for that mode: $state/umbriel-glass.toml includes
#   glass-<mode>.toml beside Umbriel's config (glass-light.toml, linked by
#   modules/umbriel.nix: params overrides for light mode), or is removed when
#   there is none. Umbriel's config.toml includes it (optional) right after
#   glass.toml. A file with an include, not a symlink: Umbriel watches an
#   include's resolved target, so it would miss a symlink being repointed;
#   it does see this file replaced or removed, and edits of the target;
# - sets the icon theme to Fluent-dark / Fluent-light (dconf for GTK,
#   kdeglobals for Qt/KDE) and tells running apps to reload their icons;
# - on a mode change, remembers Noctalia's surface opacities and Darkly's (Qt
#   apps: Dolphin...) as they were in the old mode and restores the new mode's.
#   A mode never seen before gets the old mode's values scaled by
#   appOpacity.light / appOpacity.dark. So tuning either in the settings
#   window (or darklyrc) sticks to the mode it was made in.
#
# Reduce transparency (erebor-modes, SYS-122): while
# ~/.local/state/erebor-theme-opacity/reduce exists, the links use the
# "-reduced" variants (each opacity at least my.modes.reduceTransparency.opacity)
# and Noctalia's surfaces and Darkly are raised to at least that (the bars to
# barOpacity), and Noctalia's panels go from "glass" to "soft" transparency
# (shell.panel.transparency_mode). The values they had are kept in
# reduce-base(-darkly, -panel) meanwhile;
# a mode change reads and writes those, and turning it off puts them back.
{
  flake.modules.homeManager.theme-opacity =
    {
      config,
      osConfig,
      lib,
      pkgs,
      ...
    }:
    let
      opacity = import ./_opacity.nix lib;
      rt = osConfig.my.modes.reduceTransparency;
      state = "${config.xdg.stateHome}/erebor-theme-opacity";
      raise = v: lib.max v rt.opacity;
      variant =
        mode: reduced:
        let
          f = if reduced then raise else lib.id;
          o = opacity.forValue (f opacity.appOpacity.${mode});
          dark = opacity.forValue (f opacity.appOpacity.dark);
          light = opacity.forValue (f opacity.appOpacity.light);
          zen =
            m:
            (opacity.forValue (
              f (if opacity.zenOpacity == null then opacity.appOpacity.${m} else opacity.zenOpacity)
            )).percent;
          strata =
            m: a:
            pkgs.replaceVars ../../home/noctalia/templates/strata.toml {
              mode = m;
              alpha = lib.toLower a.alpha;
            };
        in
        pkgs.linkFarm "theme-opacity-${mode}${lib.optionalString reduced "-reduced"}" {
          ghostty = pkgs.writeText "ghostty-opacity-${mode}" "background-opacity = ${o.value}\n";
          monstar = pkgs.replaceVars ../../home/monstar/config { appOpacity = o.value; };
          "vicinae.json" = pkgs.writeText "vicinae-opacity-${mode}.json" (
            builtins.toJSON { launcher_window.opacity = builtins.fromJSON o.value; }
          );
          # Templates and CSS hold both modes; the same file in each variant.
          "zed.json" = pkgs.replaceVars ../../home/noctalia/templates/zed.json {
            appOpacityAlpha = dark.alpha;
            appOpacityAlphaLight = light.alpha;
          };
          "strata-dark.toml" = strata "dark" dark;
          "strata-light.toml" = strata "light" light;
          "zen.css" = pkgs.replaceVars ../../home/zen/translucent.css {
            darkPercent = zen "dark";
            lightPercent = zen "light";
          };
        };
      variants = pkgs.linkFarm "theme-opacity" {
        dark = variant "dark" false;
        light = variant "light" false;
        dark-reduced = variant "dark" true;
        light-reduced = variant "light" true;
      };
      # Noctalia surfaces raised by reduce transparency, with their floor.
      reduceKeys =
        lib.concatMapStrings (k: "${k} ${toString rt.barOpacity}\n") [
          "bar.default.background_opacity"
          "bar.default.capsule_opacity"
          "bar.stats.background_opacity"
          "bar.stats.capsule_opacity"
        ]
        + lib.concatMapStrings (k: "${k} ${toString rt.opacity}\n") [
          "dock.background_opacity"
          "osd.background_opacity"
          "notification.background_opacity"
        ];
      script = pkgs.writeShellApplication {
        name = "erebor-theme-opacity";
        runtimeInputs = with pkgs; [
          coreutils
          gawk
          procps
          dbus
          dconf
          kdePackages.kconfig
        ];
        text = ''
          # Usage: erebor-theme-opacity [--reset] [dark|light] [--links-only]
          # Without a mode: $NOCTALIA_THEME_MODE (hooks), else Noctalia's current mode.
          # --reset: Noctalia's surface opacities were just put back to its
          # config file's values (dark mode's), e.g. a new config was loaded and
          # the runtime values removed from settings.toml. Forget the values
          # remembered per mode and derive this mode's (and reduce
          # transparency's) from the config again. Darkly is left alone.
          reset=false
          if [ "''${1:-}" = --reset ]; then
            reset=true
            shift
          fi
          export PATH="$PATH:/etc/profiles/per-user/$USER/bin"
          state=${lib.escapeShellArg state}
          variants=${variants}
          ratio=${toString opacity.ratio}
          reduce_keys=${lib.escapeShellArg reduceKeys}
          darkly_floor=${toString (builtins.floor (rt.opacity * 100 + 0.5))}
          noctalia_keys=(
            bar.default.background_opacity
            bar.default.capsule_opacity
            osd.background_opacity
            notification.background_opacity
          )
          darkly_keys=(
            DolphinSidebarOpacity
            DolphinViewOpacity
            MenuBarOpacity
            MenuOpacity
            TabBarOpacity
            ToolBarOpacity
          )
          darklyrc="''${XDG_CONFIG_HOME:-$HOME/.config}/darklyrc"

          mode="''${1:-''${NOCTALIA_THEME_MODE:-}}"
          if [ -z "$mode" ]; then
            mode="$(noctalia msg theme-mode-get 2>/dev/null || true)"
          fi
          case "$mode" in dark | light) ;; *) mode=dark ;; esac
          previous="''${NOCTALIA_THEME_MODE_PREVIOUS:-}"

          mkdir -p "$state"
          reduce=false
          [ -e "$state/reduce" ] && reduce=true
          sel="$mode"
          $reduce && sel="$mode-reduced"
          linked_before="$(cat "$state/linked" 2>/dev/null || true)"
          for f in ghostty monstar vicinae.json zed.json strata-dark.toml strata-light.toml zen.css; do
            ln -sfn "$variants/$sel/$f" "$state/$f"
          done
          printf '%s\n' "$mode" > "$state/mode"
          printf '%s\n' "$sel" > "$state/linked"
          # Strata: its Noctalia theme for this mode (rendered by Noctalia's
          # strata_dark/strata_light templates); Strata re-reads it live.
          strata="''${XDG_CONFIG_HOME:-$HOME/.config}/strata"
          mkdir -p "$strata/themes"
          ln -sfn "$strata/noctalia/$mode.toml" "$strata/themes/noctalia.toml"

          # Liquid glass: this mode's params overrides, if Umbriel's config has
          # any (glass-light.toml). Replaced by a rename and only when it
          # changes, so Umbriel reloads once, never seeing it missing between.
          glass_src="''${XDG_CONFIG_HOME:-$HOME/.config}/umbriel/glass-$mode.toml"
          glass_inc="$state/umbriel-glass.toml"
          if [ -e "$glass_src" ]; then
            glass_want="# Written by erebor-theme-opacity: $mode mode's liquid glass.
          [include.optional]
          files = [\"$glass_src\"]"
            if [ "$(cat "$glass_inc" 2>/dev/null || true)" != "$glass_want" ]; then
              printf '%s\n' "$glass_want" > "$glass_inc.tmp"
              mv -f "$glass_inc.tmp" "$glass_inc"
            fi
          else
            rm -f "$glass_inc"
          fi

          # Icon theme follows the mode too: GTK reads dconf, Qt/KDE kdeglobals.
          icons="Fluent-$mode"
          dconf write /org/gnome/desktop/interface/icon-theme "'$icons'" || true
          kwriteconfig6 --file "''${XDG_CONFIG_HOME:-$HOME/.config}/kdeglobals" \
            --group Icons --key Theme "$icons" || true
          dbus-send --session --type=signal /KIconLoader org.kde.KIconLoader.iconChanged int32:0 || true
          dbus-send --session --type=signal /KGlobalSettings org.kde.KGlobalSettings.notifyChange int32:4 int32:0 || true
          [ "''${2:-}" = --links-only ] && exit 0

          pkill -USR2 -x 'ghostty|\.ghostty-wrappe' || true
          pkill -USR1 -x monstar || true
          # Zed and Strata themes are rendered from the templates just linked.
          if [ "$linked_before" != "$sel" ]; then
            noctalia msg templates-apply >/dev/null 2>&1 || true
          fi

          # ── Noctalia surfaces and Darkly ─────────────────────────────────
          # While reduce transparency is applied, the live values are raised;
          # the real ("base") values live in reduce-base / reduce-base-darkly.
          applied=false
          [ -e "$state/reduce-applied" ] && applied=true

          floor_of() { # the reduce floor of a Noctalia key, or nothing
            awk -v k="$1" '$1 == k { print $2 }' <<< "$reduce_keys"
          }
          live_value() {
            local v
            v="$(noctalia msg config-get "$1" 2>/dev/null || true)"
            [[ "$v" =~ ^[0-9.]+$ ]] && printf '%s\n' "$v"
          }
          base_value() {
            if $applied && [ -s "$state/reduce-base" ]; then
              local v
              v="$(awk -v k="$1" '$1 == k { print $2 }' "$state/reduce-base")"
              [ -n "$v" ] && { printf '%s\n' "$v"; return; }
            fi
            live_value "$1"
          }
          set_live() {
            noctalia msg config-set "$1" "$2" >/dev/null 2>&1 || true
          }
          raised() { # value floor -> max(value, floor)
            awk -v v="$1" -v f="$2" 'BEGIN { if (f != "" && v < f) v = f; printf "%.3f", v }'
          }
          set_base() { # key value: the real value; live gets it raised while applied
            local floor=""
            if $applied; then
              floor="$(floor_of "$1")"
              if [ -n "$floor" ]; then
                awk -v k="$1" '$1 != k' "$state/reduce-base" > "$state/reduce-base.tmp" 2>/dev/null || true
                printf '%s %s\n' "$1" "$2" >> "$state/reduce-base.tmp"
                mv "$state/reduce-base.tmp" "$state/reduce-base"
              fi
            fi
            set_live "$1" "$(raised "$2" "$floor")"
          }

          # Darkly: [Style] *Opacity keys (0-100), read from darklyrc or the base file.
          darkly_read() {
            if $applied && [ -s "$state/reduce-base-darkly" ]; then
              cat "$state/reduce-base-darkly"
              return
            fi
            [ -f "$darklyrc" ] || return 0
            awk -F= -v keys="''${darkly_keys[*]}" '
              BEGIN { n = split(keys, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
              /^\[/ { style = ($0 == "[Style]") }
              style && ($1 in want) { print $1, $2 }
            ' "$darklyrc"
          }
          darkly_write() { # file of "key value" (base values) [scale]
            [ -f "$darklyrc" ] || return 0
            local floor=0
            if $applied; then floor="$darkly_floor"; cp "$1" "$state/reduce-base-darkly.tmp"; fi
            awk -v f="''${2:-1}" -v src="$1" -v floor="$floor" -v base="$state/reduce-base-darkly.tmp" '
              BEGIN {
                while ((getline line < src) > 0) {
                  split(line, p, " "); x = int(p[2] * f + 0.5); if (x > 100) x = 100
                  b[p[1]] = x; if (x < floor) x = floor; val[p[1]] = x
                }
                if (floor > 0) { printf "" > base; for (k in b) print k, b[k] > base }
              }
              /^\[/ { style = ($0 == "[Style]") }
              {
                split($0, kv, "=")
                if (style && (kv[1] in val)) { print kv[1] "=" val[kv[1]]; next }
                print
              }
            ' "$darklyrc" > "$darklyrc.tmp"
            mv "$darklyrc.tmp" "$darklyrc"
            if $applied; then mv "$state/reduce-base-darkly.tmp" "$state/reduce-base-darkly"; fi
            dbus-send --session --type=signal /DarklyStyle org.kde.Darkly.Style.reparseConfiguration || true
          }

          # A theme mode change: remember the old mode's values, load the new mode's.
          case "$previous" in dark | light) changed_mode=true ;; *) changed_mode=false ;; esac
          [ "$previous" != "$mode" ] || changed_mode=false
          if $changed_mode; then
            if [ "$mode" = light ]; then factor="$ratio"; else factor="$(awk -v r="$ratio" 'BEGIN { print 1 / r }')"; fi

            saved="$state/noctalia-$previous"
            : > "$saved.tmp"
            for k in "''${noctalia_keys[@]}"; do
              v="$(base_value "$k" || true)"
              [ -n "$v" ] && printf '%s %s\n' "$k" "$v" >> "$saved.tmp"
            done
            mv "$saved.tmp" "$saved"
            if [ -s "$state/noctalia-$mode" ]; then
              source_file="$state/noctalia-$mode"; scale=1
            else
              source_file="$saved"; scale="$factor"
            fi
            while read -r k v; do
              set_base "$k" "$(awk -v v="$v" -v f="$scale" 'BEGIN { x = v * f; if (x > 1) x = 1; printf "%.3f", x }')"
            done < "$source_file"

            if [ -f "$darklyrc" ]; then
              saved="$state/darkly-$previous"
              darkly_read > "$saved"
              if [ -s "$state/darkly-$mode" ]; then
                darkly_write "$state/darkly-$mode" 1
              else
                darkly_write "$saved" "$factor"
              fi
            fi
          fi

          # Reduce transparency's Noctalia part: remember the live values, raise them.
          noctalia_reduce_on() {
            : > "$state/reduce-base"
            while read -r k floor; do
              [ -n "$k" ] || continue
              v="$(live_value "$k" || true)"
              [ -n "$v" ] || continue
              printf '%s %s\n' "$k" "$v" >> "$state/reduce-base"
              set_live "$k" "$(raised "$v" "$floor")"
            done <<< "$reduce_keys"
            # Noctalia's panels: "glass" becomes "soft" (solid and soft stay).
            panel="$(noctalia msg config-get shell.panel.transparency_mode 2>/dev/null | tr -d "'\"" || true)"
            rm -f "$state/reduce-base-panel"
            if [ -n "$panel" ]; then
              printf '%s\n' "$panel" > "$state/reduce-base-panel"
              [ "$panel" = glass ] && set_live shell.panel.transparency_mode "'soft'"
            fi
          }

          if $reset; then
            rm -f "$state/noctalia-dark" "$state/noctalia-light" "$state/reduce-base" "$state/reduce-base-panel"
            if [ "$mode" = light ]; then
              for k in "''${noctalia_keys[@]}"; do
                v="$(live_value "$k" || true)"
                [ -n "$v" ] || continue
                set_live "$k" "$(awk -v v="$v" -v f="$ratio" 'BEGIN { x = v * f; if (x > 1) x = 1; printf "%.3f", x }')"
              done
            fi
            if $applied; then noctalia_reduce_on; fi
            exit 0
          fi

          # Reduce transparency turned on or off since the last run.
          if $reduce && ! $applied; then
            noctalia_reduce_on
            darkly_read > "$state/reduce-base-darkly.src"
            applied=true
            touch "$state/reduce-applied"
            darkly_write "$state/reduce-base-darkly.src" 1
            rm -f "$state/reduce-base-darkly.src"
          elif ! $reduce && $applied; then
            while read -r k v; do
              [ -n "$k" ] || continue
              # A value changed by hand meanwhile (not the raised one) is kept.
              now="$(live_value "$k" || true)"
              want="$(raised "$v" "$(floor_of "$k")")"
              if [ -z "$now" ] || awk -v a="$now" -v b="$want" 'BEGIN { exit !(a - b < 0.002 && b - a < 0.002) }'; then
                set_live "$k" "$v"
              fi
            done < "$state/reduce-base"
            if [ -s "$state/reduce-base-panel" ]; then
              panel="$(cat "$state/reduce-base-panel")"
              now="$(noctalia msg config-get shell.panel.transparency_mode 2>/dev/null | tr -d "'\"" || true)"
              # Put it back unless it was changed by hand meanwhile.
              if [ "$panel" = glass ] && [ "$now" = soft ]; then
                set_live shell.panel.transparency_mode "'glass'"
              fi
              rm -f "$state/reduce-base-panel"
            fi
            applied=false
            if [ -s "$state/reduce-base-darkly" ]; then
              cp "$state/reduce-base-darkly" "$state/reduce-base-darkly.src"
              rm -f "$state/reduce-applied" "$state/reduce-base-darkly"
              darkly_write "$state/reduce-base-darkly.src" 1
              rm -f "$state/reduce-base-darkly.src"
            fi
            rm -f "$state/reduce-applied" "$state/reduce-base"
          fi
        '';
      };
    in
    {
      home.packages = [ script ];
      # Keep the links valid after a rebuild (new variants), in the last mode used;
      # dark before the first switch.
      # After linkGeneration: the glass link needs ~/.config/umbriel/glass-<mode>.toml.
      home.activation.themeOpacityLinks =
        lib.hm.dag.entryAfter
          [
            "writeBoundary"
            "linkGeneration"
            "dconfSettings"
          ]
          ''
            mode="$(${pkgs.coreutils}/bin/cat ${lib.escapeShellArg state}/mode 2>/dev/null || echo dark)"
            run ${script}/bin/erebor-theme-opacity "$mode" --links-only
          '';
    };
}

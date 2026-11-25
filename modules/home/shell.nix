# Fish, the prompt and command-line tools, on Linux and macOS. The Fish
# aliases and functions are shared; on Linux the prompt is Oh My Posh's
# quick-term theme with the welcome banner, and macOS keeps its own Starship
# prompt and SSH agent.
{
  flake.modules.homeManager.shell =
    {
      config,
      lib,
      pkgs,
      osConfig ? { },
      ...
    }:
    let
      inherit (pkgs.stdenv.hostPlatform) isDarwin isLinux;
      # The Mac's nix-darwin config has no my.* options.
      my = osConfig.my or { };
      shellTasks = my.shellTasks or { enable = false; };
    in
    lib.mkMerge [
      {
        programs.bat.enable = true;
        programs.fish = {
          enable = true;
          functions.imgs = {
            description = "Preview images (default: all in current directory) with filenames";
            body = ''
              set -l files $argv
              test (count $files) -eq 0; and set files *.{png,jpg,jpeg,gif,webp,bmp,svg}
              for f in $files
                test -f $f; or continue
                set_color --bold; echo $f; set_color normal
                chafa --format=sixel --size=60x20 --animate=off $f
              end
            '';
          };
          # A function, not an alias: an alias cannot cd into its argument.
          functions.mkcd = {
            description = "Create a directory (with parents) and cd into it";
            body = ''
              if test (count $argv) -ne 1
                echo "usage: mkcd DIR" >&2
                return 1
              end
              mkdir -p -- $argv[1]; and cd -- $argv[1]
            '';
          };
          # File names as OSC 8 hyperlinks (Ctrl+click in Monstar or Ghostty).
          # eza's own --hyperlink=auto never detects these terminals, so links
          # are forced only when the output is a terminal, not a pipe.
          functions.eza = {
            description = "eza with file hyperlinks on a terminal";
            wraps = "eza";
            body = ''
              if isatty stdout
                command eza --hyperlink=always $argv
              else
                command eza $argv
              end
            '';
          };
          shellAliases = {
            fd = "fd --hyperlink=auto";
            rg = "rg --hyperlink-format=default";
            cat = "bat --style=plain --paging=never";
            catn = "bat --style=numbers --paging=never";
            t3pair = "t3 pair --base-dir ${config.home.homeDirectory}/.t3/server";
            ls = "eza --group-directories-first --icons=auto";
            ll = "eza --long --header --group-directories-first --icons=auto";
            la = "eza --all --group-directories-first --icons=auto";
            lla = "eza --long --all --header --group-directories-first --icons=auto";
            lt = "eza --tree --level=2 --group-directories-first --icons=auto";
            # Inline image previews (sixel; works in the ttyd browser terminal).
            img = "chafa --format=sixel";

            # Common Oh My Zsh Git shortcuts, available in Fish.
            g = "git";
            gst = "git status";
            gss = "git status --short";
            gsb = "git status --short --branch";
            ga = "git add";
            gaa = "git add --all";
            gapa = "git add --patch";
            gau = "git add --update";
            gd = "git diff";
            gdca = "git diff --cached";
            gds = "git diff --staged";
            gdw = "git diff --word-diff";
            gc = "git commit --verbose";
            gcmsg = "git commit --message";
            gcam = "git commit --all --message";
            gcfu = "git commit --fixup";
            gb = "git branch";
            gba = "git branch --all";
            gbd = "git branch --delete";
            gco = "git checkout";
            gcb = "git checkout -b";
            gsw = "git switch";
            gswc = "git switch --create";
            gf = "git fetch";
            gfo = "git fetch origin";
            gl = "git pull";
            gpr = "git pull --rebase";
            gp = "git push";
            gcl = "git clone --recurse-submodules";
            glo = "git log --oneline --decorate";
            glog = "git log --oneline --decorate --graph";
            gloga = "git log --oneline --decorate --graph --all";
            gm = "git merge";
            grb = "git rebase";
            grbi = "git rebase --interactive";
            grbc = "git rebase --continue";
            grba = "git rebase --abort";
            gsta = "git stash push";
            gstl = "git stash list";
            gstp = "git stash pop";
            gsts = "git stash show --patch";
          };
        };
        programs.starship = {
          enable = true;
          enableFishIntegration = true;
        };
      }

      # Linux: the welcome banner (fortune, cowsay, fastfetch) and Oh My Posh's
      # montys prompt (user request 2026-11-17, was quick-term),
      # recoloured with Noctalia's terminal palette by the community
      # "oh-my-posh" template: Noctalia renders noctalia-palette.json and its
      # hook writes noctalia.omp.json from the exported theme below. Until that
      # exists the prompt is the plain theme. Starship stays installed with
      # Noctalia's palette (STARSHIP_CONFIG in home/workstation.nix) but no longer draws
      # the Fish prompt.
      (lib.mkIf isLinux (
        let
          omp = pkgs.oh-my-posh;
          theme = "${omp}/share/oh-my-posh/themes/montys.omp.json";
          # The template maps colours by hue, which gives montys' OS segment
          # the same colour as its text, neighbouring segments one colour and
          # white text 1.3:1 on the status segment; these keep them apart.
          colourMap = {
            "#003543" = "black";
            "#00c983" = "lightCyan";
            "#ffffff" = "background";
            "#FCA17D" = "lightYellow";
            "#33658A" = "blue";
            "#2e9599" = "cyan";
          };
          communityTemplates = pkgs.fetchFromGitHub {
            owner = "noctalia-dev";
            repo = "community-templates";
            rev = "9316a212b8b7ab0aae3ef5c1f06b636c1637ca5c";
            sparseCheckout = [ "oh-my-posh" ];
            hash = "sha256-G+nuLy+nfjOTO28Njl/n92UC4djDOmi6zUQqRbwTp8g=";
          };
          # What the template's `apply.py import` would save, built here instead.
          ompSource = pkgs.runCommand "oh-my-posh-noctalia-source.omp.json" { } ''
            export HOME=$TMPDIR XDG_CACHE_HOME=$TMPDIR
            ${lib.getExe omp} config export --config ${theme} --format json >$out
          '';
          ompApply = pkgs.writeShellScript "noctalia-oh-my-posh-apply" ''
            exec ${pkgs.python3}/bin/python3 -B ${communityTemplates}/oh-my-posh/apply.py apply "$@"
          '';
        in
        {
          home.packages = [
            pkgs.zip
            omp
          ];
          programs.starship.enableFishIntegration = lib.mkForce false;
          programs.fish.interactiveShellInit = ''
            # Oh My Posh keeps its config for the whole session (cache and serve
            # daemon), so re-initialise when Noctalia rewrites the colours.
            function __omp_noctalia_init --on-event fish_prompt
                set -l config ${config.xdg.configHome}/oh-my-posh/noctalia.omp.json
                test -f $config; or set config ${theme}
                set -l key $config (path mtime $config)
                test "$key" = "$__omp_noctalia_key"; and return
                set -g __omp_noctalia_key $key
                functions -q _omp_serve_stop; and _omp_serve_stop
                ${lib.getExe omp} init fish --config $config | source
            end
            __omp_noctalia_init
          '';
          xdg.configFile."oh-my-posh/noctalia-source.omp.json".source = ompSource;
          xdg.configFile."noctalia/templates/oh-my-posh/palette.json".source =
            "${communityTemplates}/oh-my-posh/palette.json";
          xdg.configFile."oh-my-posh/noctalia-map.json".text = builtins.toJSON colourMap;
          xdg.configFile."noctalia/templates/oh-my-posh/apply".source = ompApply;
          # Noctalia runs the hook only when its colours change; rerun it so a
          # new theme or colour map shows without waiting for that.
          home.activation.ohMyPoshNoctalia = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
            if [ -f "${config.xdg.configHome}/oh-my-posh/noctalia-palette.json" ]; then
              run ${ompApply} || warnEcho "Oh My Posh: Noctalia recolour failed"
            fi
          '';
          programs.fish.functions.dlzip = {
            description = "Download a file or directory as a ZIP through ttyd";
            body = ''
              if test (count $argv) -ne 1
                echo 'usage: dlzip FILE_OR_DIRECTORY' >&2
                return 1
              end
              set -l source (realpath -e -- "$argv[1]"); or return 1
              set -l name (basename -- "$source")
              set -l tmp (mktemp -d); or return 1
              set -l archive "$tmp/$name.zip"
              begin
                cd -- (dirname -- "$source"); and ${pkgs.zip}/bin/zip -rq "$archive" "./$name"
              end
              set -l result $status
              if test $result -eq 0
                tsz "$archive"
                set result $status
              end
              command rm -f -- "$archive"
              rmdir -- "$tmp"
              return $result
            '';
          };
          xdg.configFile."fish/functions/shell_welcome.fish".source =
            pkgs.replaceVars ../../home/fish/shell_welcome.fish
              { figlet = pkgs.figlet; };
          xdg.configFile."fastfetch/shell.jsonc".source = ../../home/fastfetch/shell.jsonc;
          # No banner in the Claude desktop app's Terminal panel: agents type a
          # command into a fresh shell there, and the banner only buries its output.
          programs.fish.functions.fish_greeting.body =
            "test \"$TERM_PROGRAM\" = claude-desktop; and return; "
            + "printf '\\n'; shell_welcome; printf '\\n'"
            + lib.optionalString shellTasks.enable "; shell_tasks";
          home.activation.starshipNoctaliaConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            base="$HOME/.config/noctalia/starship-base.toml"
            palette="$HOME/.cache/noctalia/starship-palette.toml"
            target="$HOME/.config/noctalia/starship.toml"
            run ${pkgs.coreutils}/bin/mkdir -p "$(dirname "$target")"
            if [ -f "$palette" ] && [ ! -v DRY_RUN ]; then
              temporary="$(${pkgs.coreutils}/bin/mktemp "$(dirname "$target")/.starship.toml.XXXXXX")"
              {
                ${pkgs.gawk}/bin/awk '
                  $0 == "# >>> NOCTALIA STARSHIP PALETTE >>>" { skip = 1; next }
                  skip && $0 == "# <<< NOCTALIA STARSHIP PALETTE <<<" { skip = 0; next }
                  !skip { print }
                ' "$base"
                printf '\n# >>> NOCTALIA STARSHIP PALETTE >>>\n'
                ${pkgs.coreutils}/bin/cat "$palette"
                printf '# <<< NOCTALIA STARSHIP PALETTE <<<\n'
              } >"$temporary"
              if ! ${pkgs.diffutils}/bin/cmp -s "$temporary" "$target" 2>/dev/null; then
                ${pkgs.coreutils}/bin/mv "$temporary" "$target"
              else
                ${pkgs.coreutils}/bin/rm "$temporary"
              fi
            elif [ ! -f "$palette" ] && [ ! -e "$target" ]; then
              run ${pkgs.coreutils}/bin/cp "$base" "$target"
            fi
          '';
          xdg.configFile."noctalia/starship-base.toml".source = ../../home/starship.toml;
        }
      ))

      # my.shellTasks: the task script on PATH (reading my.flakePath outside a
      # checkout), alias `et`, and the board the greeting prints after the
      # banner. The board reads the live checkout, so it needs no rebuild.
      (lib.mkIf (isLinux && shellTasks.enable) (
        let
          python = lib.getExe pkgs.python3;
          inherit (my) flakePath;
          name = baseNameOf my.taskBoard.script;
          linkBase = if my.taskBoard.linkBase == null then "" else my.taskBoard.linkBase;
          tasks = pkgs.writeShellScriptBin name ''
            export TASKS_ROOT=''${TASKS_ROOT:-${flakePath}}
            exec ${python} ${my.taskBoard.script} "$@"
          '';
        in
        {
          home.packages = [ tasks ];
          programs.fish.shellAliases.et = name;
          programs.fish.functions.shell_tasks = {
            description = "Print the task board (my.shellTasks)";
            body = ''
              test -d ${flakePath}/tasks; or return 0
              set -l width 80
              if set -q COLUMNS; and test "$COLUMNS" -gt 0
                set width $COLUMNS
              end
              set -l lines (${python} ${my.taskBoard.script} --root ${flakePath} list --json 2>/dev/null \
                | ${python} ${../../home/fish/shell_tasks.py} --rows ${toString shellTasks.rows} \
                  --columns ${lib.concatStringsSep "," shellTasks.columns} --width $width \
                  --root ${flakePath} --git ${lib.getExe pkgs.git} --link-base '${linkBase}')
              test (count $lines) -gt 0; or return 0
              printf '%s\n' $lines ""
            '';
          };
        }
      ))

      # macOS: the user's own powerline prompt with fixed colours, Secretive as
      # the SSH agent, and the tools the shared aliases call (erebor has them
      # system-wide). The login shell stays Homebrew's fish; fisher keeps
      # managing its own plugins (nvm.fish) in functions/, completions/ and conf.d/.
      (lib.mkIf isDarwin {
        xdg.configFile."starship.toml".source = ../../home/starship-mac.toml;
        programs.fish.shellInit = ''
          set -gx SSH_AUTH_SOCK ${config.home.homeDirectory}/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh
        '';
        home.packages = [
          pkgs.eza
          pkgs.chafa
        ];
      })
    ];
}

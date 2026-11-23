# Record why sudo or Polkit is asking for approval, so the YubiKey
# notification and the Mac (through its approval tunnel) can show it.
{
  flake.modules.nixos.approval-reason =
    {
      config,
      lib,
      pkgs,
      ...
    }:

    let
      enabled = config.my.yubikey.enable || config.my.macApproval.enable;
      dir = "/run/auth-reason";
      # Runs as root from PAM before the Mac and YubiKey steps. It never fails
      # the stack: it is optional and always exits 0.
      recordReason = pkgs.writeShellScript "record-auth-reason" ''
        PATH=${lib.makeBinPath [ pkgs.coreutils ]}
        test "$PAM_TYPE" = auth || exit 0
        # sudo reports the invoking user as PAM_RUSER; Polkit only sets PAM_USER.
        user="''${PAM_RUSER:-$PAM_USER}"
        [[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || exit 0
        case "$PAM_SERVICE" in
          sudo)
            # pam_exec's parent is the sudo process asking for authentication.
            what="sudo $(tr '\0' ' ' < /proc/$PPID/cmdline 2>/dev/null | cut -d' ' -f2- | cut -c1-200)"
            ;;
          polkit-1) what="Polkit: an app asks for administrator rights" ;;
          *) what="$PAM_SERVICE" ;;
        esac
        what="$(printf '%s' "$what" | tr -d '\t\r\n')"
        tmp="$(mktemp "${dir}/.reason.XXXXXX")" || exit 0
        printf '%s\t%s\n' "$(date +%s)" "$what" > "$tmp"
        chown "$user" "$tmp" && chmod 0600 "$tmp" && mv -f "$tmp" "${dir}/$user" || rm -f "$tmp"
        exit 0
      '';
      # Streams new reasons, one line each. The Mac's approval tunnel runs it in
      # place of `sleep infinity` and turns each line into a macOS notification.
      reasonStream = pkgs.writeShellScriptBin "auth-reason-stream" ''
        PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.inotify-tools
          ]
        }
        # Two sources: sudo/Polkit (PAM, root-written) and approvald requests
        # (the session's approval agent writes $XDG_RUNTIME_DIR/approval-reason).
        runtime="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        files=("${dir}/$(id -un)" "$runtime/approval-reason")
        dirs=("${dir}")
        [ -d "$runtime" ] && dirs+=("$runtime")
        declare -A last
        while true; do
          inotifywait -qq -e close_write,moved_to "''${dirs[@]}" || sleep 1
          for file in "''${files[@]}"; do
            [ -r "$file" ] || continue
            IFS=$'\t' read -r stamp what < "$file" || continue
            [ "$stamp" != "''${last[$file]:-}" ] || continue
            last[$file]="$stamp"
            printf '%s\n' "$what"
          done
        done
      '';
      reasonRule = order: {
        inherit order;
        control = "optional";
        modulePath = "${pkgs.pam}/lib/security/pam_exec.so";
        # seteuid: without it pam_exec runs the script as the calling user, who
        # can't write the root-owned reason directory.
        args = [
          "quiet"
          "seteuid"
          (toString recordReason)
        ];
      };
    in
    {
      config = lib.mkIf enabled {
        systemd.tmpfiles.rules = [ "d ${dir} 0755 root root -" ];
        # Before pam_rssh (Mac) and pam_u2f (YubiKey).
        security.pam.services.sudo.rules.auth.reason = reasonRule (
          config.security.pam.services.sudo.rules.auth.rssh.order - 100
        );
        security.pam.services.polkit-1.rules.auth.reason = reasonRule (
          config.security.pam.services.polkit-1.rules.auth.rssh.order - 100
        );
        environment.systemPackages = [ reasonStream ];
      };
    };
}

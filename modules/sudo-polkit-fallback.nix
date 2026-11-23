# Let sudo fall back to a graphical Polkit prompt when the YubiKey touch is
# unavailable. A sufficient PAM step after pam_u2f asks Polkit (as root, with
# pkcheck) whether the process that called sudo may run it; Polkit's agent in
# that process's session shows the prompt. Failure, cancel or no agent falls
# through to the Unix password, so the step can only add a way in that Polkit
# already allows, never remove one.
{
  flake.modules.nixos.sudo-polkit-fallback =
    {
      config,
      lib,
      pkgs,
      ...
    }:

    let
      actionId = "org.nixos.sudo-polkit-fallback";
      policy = pkgs.writeTextDir "share/polkit-1/actions/${actionId}.policy" ''
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
         "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
        <policyconfig>
          <action id="${actionId}">
            <description>Run a command as root with sudo</description>
            <message>sudo wants to run: $(command)</message>
            <defaults>
              <allow_any>no</allow_any>
              <allow_inactive>no</allow_inactive>
              <allow_active>auth_admin</allow_active>
            </defaults>
          </action>
        </policyconfig>
      '';
      # Runs as root from pam_exec; its parent is the sudo process.
      fallback = pkgs.writeShellScript "sudo-polkit-fallback" ''
        PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.gnused
            pkgs.util-linux
          ]
        }
        test "$PAM_TYPE" = auth || exit 1
        test "$PAM_SERVICE" = sudo || exit 1
        [[ $PAM_RUSER =~ ^[a-z_][a-z0-9_-]*$ ]] || exit 1
        ruid="$(id -u -- "$PAM_RUSER")" || exit 1
        # The subject is sudo's caller (the user's shell or script), pinned by
        # its start time and uid so a reused PID cannot stand in for it.
        caller="$(sed -n 's/^PPid:[[:space:]]*//p' /proc/$PPID/status)"
        [[ $caller =~ ^[0-9]+$ ]] && [ "$caller" -gt 1 ] || exit 1
        start="$(sed 's/.*) //' /proc/$caller/stat | cut -d' ' -f20)"
        [[ $start =~ ^[0-9]+$ ]] || exit 1
        [ "$(stat -c %u /proc/$caller)" = "$ruid" ] || exit 1
        command="$(tr '\0' ' ' < /proc/$PPID/cmdline | cut -d' ' -f2- | tr -d '\t\r\n' | cut -c1-200)"
        timeout --kill-after=2s 60s ${config.security.polkit.package.bin}/bin/pkcheck \
          --action-id ${actionId} --process "$caller,$start,$ruid" \
          --detail command "$command" --allow-user-interaction </dev/null 2>&1 | logger -t sudo-polkit-fallback
        exit "''${PIPESTATUS[0]}"
      '';
    in
    lib.mkIf config.my.yubikey.sudoPolkitFallback {
      security.polkit.enable = true;
      environment.systemPackages = [ policy ];
      # WARNING: security.pam.services.*.rules is experimental; recheck the
      # generated /etc/pam.d/sudo on NixOS upgrades.
      security.pam.services.sudo.rules.auth.polkitFallback = {
        order = config.security.pam.services.sudo.rules.auth.u2f.order + 100;
        control = "sufficient";
        modulePath = "${pkgs.pam}/lib/security/pam_exec.so";
        args = [
          "quiet"
          # Run as root (the effective uid), not as the user: only root may
          # ask Polkit about another process, and the user cannot touch it.
          "seteuid"
          (toString fallback)
        ];
      };
    };
}

# Plymouth hands the screen straight to the Noctalia greeter, the way GDM does,
# instead of quitting first and leaving a black or console gap.
# - plymouth-quit.service is ordered after greetd and the handoff, so the splash
#   stays up while greetd starts; greetd no longer waits for plymouth-quit-wait
#   (which only finishes once Plymouth has exited).
# - Before greetd starts the greeter, `plymouth deactivate` stops Plymouth
#   drawing and drops DRM master; its last frame stays on screen until the
#   greeter's compositor takes over the display.
# - Once the greeter client is running, `plymouth quit --retain-splash` ends
#   Plymouth without clearing the screen. If greetd fails, plymouth-quit runs.
# - patches/noctalia-greeter-keep-splash.patch: the greeter's compositor copies
#   the splash frame still on screen before its first modeset and shows it
#   instead of black until the greeter has drawn a full-size frame. Source:
#   ~/src/noctalia-greeter-splash, branch keep-plymouth-splash on the pinned
#   input rev; the patch is `git format-patch -1` there.
# - patches/greetd-keep-plymouth-splash.patch: greetd leaves the VT in graphics
#   mode (no text mode, no clear) while /run/plymouth/pid exists.
# plymouthd accepts commands only from root, so this runs in system units, not
# in the greeter (which runs as the greeter user).
{
  flake.modules.nixos.plymouth-greeter-handoff =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      plymouth = "${config.boot.plymouth.package}/bin/plymouth";
      greeterUser = config.services.greetd.settings.default_session.user;
    in
    lib.mkMerge [
      # Kept apart from the greetd condition: the greeter package feeds greetd's config.
      (lib.mkIf config.boot.plymouth.enable {
        programs.noctalia.greeterPatches = lib.mkOrder 2000 [
          ../patches/noctalia-greeter-keep-splash.patch
        ];
      })
      (lib.mkIf (config.boot.plymouth.enable && config.services.greetd.enable) {
        # Drops greetd's After=plymouth-quit-wait.service (nixpkgs option).
        services.greetd.greeterManagesPlymouth = true;

        # greetd switches the VT to text mode and clears it before every session,
        # which lets the console repaint over the splash; skip that while
        # Plymouth is still running (only the greeter's start at boot).
        services.greetd.package = pkgs.greetd.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ../patches/greetd-keep-plymouth-splash.patch ];
        });

        systemd.services.greetd = {
          after = [ "plymouth-start.service" ];
          onFailure = [ "plymouth-quit.service" ];
          serviceConfig.ExecStartPre = [
            "-${plymouth} deactivate"
            # TEMPORARY diagnostic (2026-11-16): DRM state while the splash is
            # still Plymouth's, to find why the greeter's takeover blanks DP-1.
            # Kernel KMS debug on until the handoff ends.
            "-${pkgs.bash}/bin/sh -c 'mkdir -p /run/drm-snapshot && ${pkgs.drm_info}/bin/drm_info -j > /run/drm-snapshot/before.json 2>&1; ${pkgs.drm_info}/bin/drm_info > /run/drm-snapshot/before.txt 2>&1; echo 0x14 > /sys/module/drm/parameters/debug'"
          ];
        };

        # Not Conflicts= with greetd (as GDM does): any later start of
        # plymouth-quit, e.g. by a switch, would then stop greetd and the user's
        # session. Ordered after the handoff instead, it finds Plymouth gone and
        # does nothing, at boot and after.
        systemd.services.plymouth-quit.after = [
          "greetd.service"
          "plymouth-greeter-handoff.service"
        ];

        systemd.services.plymouth-greeter-handoff = {
          description = "Hand the Plymouth splash over to the greeter";
          after = [ "greetd.service" ];
          wantedBy = [ "greetd.service" ];
          path = [ pkgs.procps ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ${plymouth} --ping || exit 0
            # Wait (up to 15 s) for the greeter client, then give it a moment to
            # draw its first frame before Plymouth exits.
            for _ in $(seq 150); do
              if pgrep -u ${greeterUser} -f '^[^ ]*/bin/noctalia-greeter( |$)' >/dev/null; then
                sleep 1.5
                break
              fi
              sleep 0.1
            done
            # TEMPORARY diagnostic: DRM state once the greeter has drawn.
            ${pkgs.drm_info}/bin/drm_info -j > /run/drm-snapshot/after.json 2>&1 || true
            ${pkgs.drm_info}/bin/drm_info > /run/drm-snapshot/after.txt 2>&1 || true
            echo 0 > /sys/module/drm/parameters/debug || true
            ${plymouth} quit --retain-splash
          '';
        };
      })
    ];
}

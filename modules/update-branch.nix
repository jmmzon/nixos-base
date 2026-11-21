# Weekly tested update branch (my.updateBranch.enable): a user timer runs
# my.updateBranch.script in the checkout (my.flakePath). The script is the
# host flake's own; it is expected to update the lock on a branch, build and
# compare the result, and never activate, so the user reviews and lands it.
{
  flake.modules.nixos.update-branch =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.my.updateBranch;
      script = pkgs.writeShellApplication {
        name = "erebor-update-branch";
        runtimeInputs = with pkgs; [
          bash # erebor-rebuild and erebor-diff run through env bash
          coreutils
          diffutils
          findutils
          gnugrep
          gnused
          git
          jq
          libnotify
          openssh # git fetches the SSH submodules (apps/*)
          util-linux # flock, for erebor-rebuild
          config.system.build.nixos-rebuild
        ];
        text = builtins.readFile cfg.script;
      };
    in
    {
      options.my.updateBranch = {
        enable = lib.mkEnableOption "a weekly user timer that prepares a tested flake update branch";
        script = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = lib.literalExpression "../../../scripts/update-branch";
          description = ''
            Bash script the timer runs in the checkout ($EREBOR_REPO, my.flakePath),
            wrapped with git, nix, jq and coreutils on its PATH.
          '';
        };
        onCalendar = lib.mkOption {
          type = lib.types.str;
          default = "Sun 03:00";
          description = "systemd OnCalendar expression for the run.";
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.script != null;
            message = "my.updateBranch.enable needs my.updateBranch.script: the script that prepares the branch.";
          }
          {
            assertion = config.my.flakePath != null;
            message = "my.updateBranch.enable needs my.flakePath: the checkout the update branch is made from.";
          }
        ];
        systemd.user.services.erebor-update-branch = {
          description = "Prepare a tested flake update on agent/flake-update";
          # nix comes from the system profile so the daemon's version is used.
          path = [ config.nix.package ];
          environment.EREBOR_REPO = config.my.flakePath;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe script;
            Nice = 19;
            IOSchedulingClass = "idle";
            CPUSchedulingPolicy = "idle";
          };
          # Only for the main user; other accounts have no checkout.
          unitConfig.ConditionUser = config.my.user.name;
        };
        systemd.user.timers.erebor-update-branch = {
          description = "Weekly tested flake update branch";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.onCalendar;
            Persistent = true;
            RandomizedDelaySec = "30min";
          };
        };
      };
    };
}

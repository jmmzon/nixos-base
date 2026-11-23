# VM tests (checks.x86_64-linux.vm-<name>), built by `nix flake check`.
{ config, ... }:
let
  inherit (config.flake.modules) nixos;
in
{
  perSystem =
    { pkgs, lib, ... }:
    {
      checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
        # sudo's Polkit fallback: a Polkit YES lets sudo through with no
        # terminal and no password; a NO falls through to the password.
        vm-sudo-polkit-fallback = pkgs.testers.runNixOSTest {
          name = "sudo-polkit-fallback";
          nodes.machine = {
            imports = [
              nixos.my
              nixos.sudo-polkit-fallback
            ];
            my.yubikey.sudoPolkitFallback = true;
            users.users = lib.genAttrs [ "alice" "bob" ] (_: {
              isNormalUser = true;
              extraGroups = [ "wheel" ];
              password = "pw";
            });
            security.polkit.extraConfig = ''
              polkit.addRule(function (action, subject) {
                if (action.id == "org.nixos.sudo-polkit-fallback")
                  return subject.user == "alice" ? polkit.Result.YES : polkit.Result.NO;
              });
            '';
          };
          testScript = ''
            machine.wait_for_unit("multi-user.target")
            machine.succeed("grep -q 'sudo-polkit-fallback' /etc/pam.d/sudo")
            # Step order: u2f (if any) < polkit fallback < unix password.
            machine.succeed("awk '/^auth/ && /sudo-polkit-fallback/ {f=NR} /^auth/ && /pam_unix/ {u=NR} END {exit !(f && u && f < u)}' /etc/pam.d/sudo")
            machine.succeed("su - alice -c 'sudo -k; sudo true </dev/null'")
            machine.fail("su - bob -c 'sudo -k; sudo true </dev/null'")
            machine.succeed("su - bob -c 'sudo -k; echo pw | sudo -S true'")
            machine.fail("su - bob -c 'sudo -k; echo wrong | sudo -S true'")
          '';
        };
      };
    };
}

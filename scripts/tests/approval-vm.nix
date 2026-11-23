# VM test of approvald (modules/approval): callers, the fake method's
# approve/deny/timeout, refused peers, and sudo's PAM step with its password
# fallback. Run (in the base flake's directory):
#   nix build --impure -f scripts/tests/approval-vm.nix --argstr flake "$PWD" -L
# Not a flake check (needs KVM, ~1 min).
{ flake }:
let
  f = builtins.getFlake (toString flake);
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  inherit (f.modules) nixos;
in
pkgs.testers.runNixOSTest {
  name = "approval";
  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        nixos.my
        nixos.approval
      ];
      my.user.name = "alice";
      users.users = {
        alice = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
          password = "alicepw";
        };
        tester = {
          isNormalUser = true;
          extraGroups = [ "approval-clients" ];
        };
        stranger = {
          isNormalUser = true;
          extraGroups = [ "approval-clients" ];
        };
        intruder.isNormalUser = true;
      };
      my.approval = {
        testing = true;
        methods.fake = {
          enable = true;
          answerFile = "/run/fake-answer";
          delay = 1;
        };
        callers.tester = {
          users = [ "tester" ];
          methods = [ "fake" ];
          rateLimit.burst = 20;
          rateLimit.perMinute = 60;
        };
        pam.sudo = {
          enable = true;
          methods = [ "fake" ];
          timeout = 5;
        };
      };
      environment.systemPackages = [ pkgs.pamtester ];
    };

  testScript = ''
    machine.wait_for_unit("sockets.target")
    machine.wait_for_unit("approvald.service")

    def answer(a):
        machine.succeed(f"echo {a} > /run/fake-answer")

    def ask(user, extra=""):
        return machine.execute(f"su {user} -c 'approval test --risk high {extra}' 2>&1")

    with subtest("approved"):
        answer("approve")
        rc, out = ask("tester")
        assert rc == 0 and '"approved"' in out, out
        assert '"pending"' in out, out

    with subtest("denied"):
        answer("deny")
        rc, out = ask("tester")
        assert rc != 0 and '"denied"' in out, out

    with subtest("timeout"):
        answer("timeout")
        rc, out = ask("tester", "--timeout 3")
        assert rc != 0 and '"timeout"' in out, out

    with subtest("unknown method and bad request"):
        answer("approve")
        rc, out = ask("tester", "--methods phone")
        assert rc != 0 and "no-method" in out, out
        rc, out = ask("tester", "--action 'Bad Action'")
        assert rc != 0 and "bad-request" in out, out

    with subtest("refused peers"):
        rc, out = ask("intruder")
        assert rc != 0 and "PermissionError" in out, out
        rc, out = ask("stranger")
        assert rc != 0 and "forbidden" in out, out

    with subtest("decisions are logged"):
        machine.succeed("journalctl -u approvald | grep -q 'tester test (high): asking fake'")

    with subtest("sudo PAM step"):
        answer("approve")
        machine.succeed("pamtester sudo alice authenticate < /dev/null")
        answer("deny")
        machine.fail("echo wrong | pamtester sudo alice authenticate")
        # The password still works after a denial and with the daemon down.
        machine.succeed("echo alicepw | pamtester sudo alice authenticate")
        machine.succeed("systemctl stop approvald.service approvald-request.socket approvald-agent.socket")
        machine.succeed("echo alicepw | pamtester sudo alice authenticate")
        machine.fail("echo wrong | pamtester sudo alice authenticate")
  '';
}

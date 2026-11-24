# VM test of erebor-sysd (modules/control-daemon): the polkit grants to its
# system user (power profile, a stand-in for the Windows reboot unit), the
# policy (none / approve through approvald's fake method / deny), refused
# peers, and forwarding to a fake desktopd on the session uplink. Run (in the
# base flake's directory):
#   nix build --impure -f scripts/tests/control-daemon-vm.nix --argstr flake "$PWD" -L
# Not a flake check (needs KVM, ~1 min).
{ flake }:
let
  f = builtins.getFlake (toString flake);
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  inherit (f.modules) nixos;
  # Stands in for erebor-desktopd: the shared server, dialling the uplink.
  fakeDesktop = pkgs.writeScript "fake-desktopd" ''
    #!${pkgs.python3}/bin/python3
    import asyncio, os, sys, tempfile
    sys.path.insert(0, "${f}/modules/control-daemon")
    from erebor_desktop.server import Daemon, Feature

    state = {"look": "glass", "layout": "glass"}
    f = Feature("presets", events=["preset-changed"], flat_snapshot=True)
    f.snapshot = lambda ctx: dict(state)

    @f.command("get-noctalia-preset")
    async def get(ctx, req):
        return {"ok": True, **state}

    @f.command("set-noctalia-preset", mutates=True)
    async def set_(ctx, req):
        state["look"] = req.get("look") or state["look"]
        ctx.emit("preset-changed", **state)
        return {"ok": True, **state}

    async def main():
        d = Daemon([f], os.path.join(tempfile.mkdtemp(), "desktop.sock"))
        await d.start()
        d.dial("/run/erebor/sysd-session.sock", min_delay=0.2)
        await asyncio.Event().wait()

    asyncio.run(main())
  '';
  # Any user can reach the uplink socket; sysd must refuse other uids.
  probeUplink = pkgs.writeScript "probe-uplink" ''
    #!${pkgs.python3}/bin/python3
    import socket
    s = socket.socket(socket.AF_UNIX)
    s.connect("/run/erebor/sysd-session.sock")
    s.settimeout(5)
    print(repr(s.recv(100)))
  '';
in
pkgs.testers.runNixOSTest {
  name = "control-daemon";
  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        nixos.my
        nixos.approval
        nixos.control-daemon
      ];
      my.user.name = "alice";
      users.users = {
        alice.isNormalUser = true;
        bob.isNormalUser = true;
        intruder.isNormalUser = true;
      };
      services.power-profiles-daemon.enable = true;
      my.approval = {
        testing = true;
        methods.fake = {
          enable = true;
          answerFile = "/run/fake-answer";
        };
      };
      # The Windows reboot stand-in: a root oneshot that leaves a mark.
      systemd.services.test-reboot = {
        serviceConfig.Type = "oneshot";
        script = "touch /run/rebooted";
      };
      my.controlDaemon = {
        enable = true;
        rebootWindowsUnit = "test-reboot.service";
        approval.methods = [ "fake" ];
        callers = {
          local.users = [ "alice" ];
          other.users = [ "bob" ];
        };
        actions = {
          set-power-profile.approval = "none";
          reboot-windows = {
            approval = "approve";
            callers.other = "deny";
          };
          power-off.approval = "deny";
          "desktop.set-noctalia-preset" = {
            approval = "none";
            origins.dashboard = "approve";
          };
        };
      };
    };

  testScript = ''
    import json

    machine.wait_for_unit("sockets.target")
    machine.wait_for_unit("erebor-sysd.service")
    machine.wait_until_succeeds("powerprofilesctl get")  # D-Bus activated

    def answer(a):
        machine.succeed(f"echo {a} > /run/fake-answer")

    def sys(user, args):
        return machine.execute(f"su {user} -c 'erebor-sys --json {args}' 2>&1")

    def final(out):
        return json.loads(out.strip().splitlines()[-1])

    with subtest("no-approval action through polkit, without a session"):
        rc, out = sys("alice", "set-power-profile profile=power-saver")
        assert rc == 0 and final(out) == {"ok": True, "profile": "power-saver"}, out
        machine.succeed("powerprofilesctl get | grep -qx power-saver")
        rc, out = sys("alice", "get-power-profile")
        assert final(out)["profile"] == "power-saver", out

    with subtest("deny action refused"):
        rc, out = sys("alice", "power-off")
        assert rc != 0 and final(out)["code"] == "forbidden", out
        rc, out = sys("bob", "reboot-windows")
        assert rc != 0 and final(out)["code"] == "forbidden", out
        machine.succeed("journalctl -u erebor-sysd | grep -q 'power-off: caller=local.*refused by policy'")

    with subtest("approve action waits for approval"):
        answer("deny")
        rc, out = sys("alice", "reboot-windows")
        assert rc != 0 and final(out)["result"] == "denied", out
        machine.fail("test -e /run/rebooted")
        answer("approve")
        rc, out = sys("alice", "reboot-windows origin=dashboard origin_user=carol")
        assert rc == 0 and "approval-pending" in out and final(out) == {"ok": True}, out
        machine.succeed("test -e /run/rebooted")
        machine.succeed("journalctl -u approvald | grep -q 'sysd reboot-windows'")

    with subtest("the grant is sysd's, not the user's"):
        machine.fail("su alice -c 'systemctl --no-ask-password start test-reboot.service'")

    with subtest("refused peers"):
        rc, out = machine.execute("su intruder -c 'erebor-sys get-power-profile' 2>&1")
        assert rc != 0 and "not reachable" in out, out
        rc, out = machine.execute("su intruder -c ${probeUplink} 2>&1")
        assert "b'''" in out, out
        machine.succeed("journalctl -u erebor-sysd | grep -q 'uplink refused'")

    with subtest("forwarding to the desktop session"):
        rc, out = sys("alice", "desktop.get-noctalia-preset")
        assert rc != 0 and final(out)["code"] == "no-session", out
        machine.succeed("systemd-run --uid=alice --unit=fake-desktopd ${fakeDesktop}")
        machine.wait_until_succeeds("journalctl -u erebor-sysd | grep -q 'desktop session up'")
        rc, out = sys("alice", "desktop.get-noctalia-preset")
        assert rc == 0 and final(out)["look"] == "glass", out
        rc, out = sys("alice", "desktop.set-noctalia-preset look=glass-pbsio2")
        assert rc == 0 and final(out)["look"] == "glass-pbsio2", out
        answer("deny")
        rc, out = sys("alice", "desktop.set-noctalia-preset look=glass origin=dashboard")
        assert rc != 0 and final(out)["result"] == "denied", out
        machine.succeed("systemctl stop fake-desktopd")
        machine.wait_until_succeeds("journalctl -u erebor-sysd | grep -q 'desktop session down'")
        rc, out = sys("alice", "desktop.get-noctalia-preset")
        assert final(out)["code"] == "no-session", out
  '';
}

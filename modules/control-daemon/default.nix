# erebor-sysd: a system-wide control daemon for machine-level actions (power
# profile, sleep, power off, reboot into Windows) and for desktop commands,
# which it forwards to the session's erebor-desktopd over an uplink that
# desktopd opens. Each action has a declarative policy (none / approve /
# deny, per caller and origin); "approve" asks approvald
# (docs/approval-protocol.md). It runs as its own system user; privileged
# steps are polkit grants to that user for the actions the policy lists.
# docs/control-daemon.md describes the design and the protocol.
#
# erebor_desktop/server.py is the asyncio JSON-per-line server it is built on,
# shared with erebor-desktopd (which copies it from here; import path
# erebor_desktop.server).
{ lib, ... }:
let
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./run.py
      ./erebor_desktop
      ./sysd
    ];
  };
  levels = [
    "none"
    "approve"
    "deny"
  ];
  # The daemon's own actions (sysd/actions.py); desktop.* are forwarded.
  ownActions = [
    "get-power-profile"
    "set-power-profile"
    "sleep"
    "power-off"
    "reboot-windows"
  ];
in
{
  perSystem =
    { pkgs, ... }:
    {
      # Unit and socket tests: the server, the policy, approvald-fake for
      # approvals, a fake desktopd on the uplink.
      checks.control-daemon-unit =
        pkgs.runCommand "control-daemon-unit"
          {
            nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.pytest ])) ];
          }
          ''
            cp -r ${./.} src && chmod -R u+w src && cd src
            export APPROVAL_RUN=${../approval}/run.py
            export PYTHONPATH=$PWD
            python3 -m pytest -q -p no:cacheprovider tests
            python3 -m unittest test_server test_server_extras
            touch $out
          '';
    };

  flake.modules.nixos.control-daemon =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.my.controlDaemon;
      approvalMethods = config.my.approval.methods;
      enabledApprovalMethods = lib.attrNames (lib.filterAttrs (_: m: m.enable) approvalMethods);

      # Levels an action can end up with, over its default, callers and origins.
      levelsOf = a: [ a.approval ] ++ lib.attrValues a.callers ++ lib.attrValues a.origins;
      needsApproval = lib.any (a: lib.elem "approve" (levelsOf a)) (lib.attrValues cfg.actions);
      # Grants only for actions that are not refused in every case.
      allowed = name: cfg.actions ? ${name} && lib.any (l: l != "deny") (levelsOf cfg.actions.${name});

      configFile = pkgs.writeText "erebor-sysd.json" (
        builtins.toJSON {
          inherit (cfg) callers rebootWindowsUnit;
          actions = lib.mapAttrs (_: a: {
            inherit (a)
              approval
              callers
              origins
              risk
              ;
            methods = if a.methods == null then [ ] else a.methods;
          }) cfg.actions;
          approval = {
            socket = "/run/approvald/request.sock";
            inherit (cfg.approval) methods timeout;
          };
          session.user = cfg.sessionUser;
        }
      );

      run = role: "${pkgs.python3}/bin/python3 -I ${src}/run.py ${role}";
      cli = pkgs.writeShellScriptBin "erebor-sys" ''exec ${run "ctl"} "$@"'';

      level = lib.types.enum levels;
    in
    {
      options.my.controlDaemon = {
        enable = lib.mkEnableOption "erebor-sysd, the system control daemon (`erebor-sys`)";
        sessionUser = lib.mkOption {
          type = lib.types.str;
          default = config.my.user.name;
          defaultText = lib.literalExpression "config.my.user.name";
          description = "The user whose erebor-desktopd may connect as the desktop session.";
        };
        callers = lib.mkOption {
          default = { };
          example = lib.literalExpression ''{ local.users = [ "alice" ]; admins.groups = [ "wheel" ]; }'';
          description = ''
            Who may connect, by the peer's user (matched first) or group. Users
            named here join the socket's group, `erebor-control`. Anyone else
            is refused.
          '';
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                users = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "Users that are this caller.";
                };
                groups = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "Groups (primary or supplementary) that are this caller.";
                };
              };
            }
          );
        };
        actions = lib.mkOption {
          default = { };
          example = lib.literalExpression ''
            {
              set-power-profile.approval = "none";
              reboot-windows = {
                approval = "approve";
                callers.local = "none";
                origins.dashboard = "approve";
              };
              "desktop.set-noctalia-preset".approval = "none";
            }
          '';
          description = ''
            The policy, per action: ${lib.concatStringsSep ", " ownActions}, or a
            desktop command forwarded to erebor-desktopd as `desktop.<command>`.
            An action not listed is refused, except read-only ones
            (`get-*`, `list-*`, `status`), which any caller may run.
          '';
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                approval = lib.mkOption {
                  type = level;
                  default = "deny";
                  description = "`none` runs it, `approve` asks approvald first, `deny` refuses it.";
                };
                callers = lib.mkOption {
                  type = lib.types.attrsOf level;
                  default = { };
                  description = "Per caller (a name in `callers`), replacing `approval`.";
                };
                origins = lib.mkOption {
                  type = lib.types.attrsOf level;
                  default = { };
                  description = ''
                    Per origin the request names (`dashboard`, ...). Not proven, so it
                    can only make approval stricter than the caller's level.
                  '';
                };
                risk = lib.mkOption {
                  type = lib.types.enum [
                    "low"
                    "high"
                  ];
                  default = "high";
                  description = "The approval's risk (`high` excludes weak methods).";
                };
                methods = lib.mkOption {
                  type = lib.types.nullOr (lib.types.listOf lib.types.str);
                  default = null;
                  description = "Approval methods for this action; default `approval.methods`.";
                };
              };
            }
          );
        };
        approval = {
          methods = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = lib.filter (m: lib.elem m enabledApprovalMethods) [
              "phone"
              "yubikey"
              "mac"
            ];
            defaultText = lib.literalExpression ''the enabled ones of [ "phone" "yubikey" "mac" ]'';
            description = ''
              Methods sysd may ask approvald for (its caller ceiling). The desktop
              method is left out by default: any process of the user can answer it.
            '';
          };
          timeout = lib.mkOption {
            type = lib.types.ints.between 5 300;
            default = 60;
            description = "Seconds an approval waits.";
          };
        };
        rebootWindowsUnit = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default =
            if config.systemd.services ? dashboard-reboot-windows then
              "dashboard-reboot-windows.service"
            else
              null;
          defaultText = lib.literalExpression ''"dashboard-reboot-windows.service" when it exists'';
          description = "The unit `reboot-windows` starts (a fixed, root-run oneshot).";
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = lib.all (n: lib.elem n ownActions || lib.hasPrefix "desktop." n) (
              lib.attrNames cfg.actions
            );
            message = "my.controlDaemon.actions: unknown ${
              toString (
                lib.filter (n: !(lib.elem n ownActions || lib.hasPrefix "desktop." n)) (lib.attrNames cfg.actions)
              )
            } (known: ${toString ownActions}, desktop.<command>).";
          }
          {
            assertion = lib.all (a: lib.all (c: cfg.callers ? ${c}) (lib.attrNames a.callers)) (
              lib.attrValues cfg.actions
            );
            message = "my.controlDaemon.actions.<name>.callers names a caller not in my.controlDaemon.callers.";
          }
          {
            assertion = needsApproval -> (config.my.approval.enable && cfg.approval.methods != [ ]);
            message = "my.controlDaemon: an action needs approval, but approvald (my.approval) has none of my.controlDaemon.approval.methods enabled.";
          }
          {
            assertion = allowed "reboot-windows" -> cfg.rebootWindowsUnit != null;
            message = "my.controlDaemon.actions.reboot-windows needs my.controlDaemon.rebootWindowsUnit (the dashboard-control aspect provides one).";
          }
        ];

        users.groups.erebor-sysd = { };
        users.groups.erebor-control = { };
        users.users =
          lib.genAttrs
            (lib.remove "root" (lib.unique (lib.concatMap (c: c.users) (lib.attrValues cfg.callers))))
            (_: {
              extraGroups = [ "erebor-control" ];
            })
          // {
            erebor-sysd = {
              isSystemUser = true;
              group = "erebor-sysd";
            };
          };

        # sysd asks approvald as its own caller.
        my.approval.callers.sysd = lib.mkIf needsApproval {
          users = [ "erebor-sysd" ];
          inherit (cfg.approval) methods;
        };

        systemd.sockets.erebor-sysd-control = {
          description = "erebor-sysd requests";
          wantedBy = [ "sockets.target" ];
          socketConfig = {
            ListenStream = "/run/erebor/sysd.sock";
            SocketMode = "0660";
            SocketGroup = "erebor-control";
            FileDescriptorName = "control";
            Service = "erebor-sysd.service";
          };
        };
        # Any user may connect; the daemon accepts only sessionUser's desktopd.
        systemd.sockets.erebor-sysd-session = {
          description = "erebor-sysd desktop session uplink";
          wantedBy = [ "sockets.target" ];
          socketConfig = {
            ListenStream = "/run/erebor/sysd-session.sock";
            SocketMode = "0666";
            FileDescriptorName = "session";
            Service = "erebor-sysd.service";
          };
        };

        systemd.services.erebor-sysd = {
          description = "System control daemon (erebor-sys)";
          # Started at boot: the session's desktopd connects to it.
          wantedBy = [ "multi-user.target" ];
          requires = [
            "erebor-sysd-control.socket"
            "erebor-sysd-session.socket"
          ];
          path = [ config.systemd.package ];
          environment.SYSD_CONFIG = configFile;
          serviceConfig = {
            Type = "notify";
            ExecStart = run "sysd";
            Sockets = [
              "erebor-sysd-control.socket"
              "erebor-sysd-session.socket"
            ];
            User = "erebor-sysd";
            Group = "erebor-sysd";
            Restart = "on-failure";
            UMask = "0077";
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            PrivateIPC = true;
            PrivateNetwork = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            ProtectProc = "invisible";
            ProcSubset = "pid";
            RestrictAddressFamilies = [ "AF_UNIX" ];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            SystemCallArchitectures = "native";
            SystemCallFilter = [
              "@system-service"
              "~@privileged"
            ];
            CapabilityBoundingSet = "";
          };
        };

        # Narrow grants to sysd's user, only for actions the policy can allow.
        security.polkit.enable = true;
        security.polkit.extraConfig = ''
          polkit.addRule(function(action, subject) {
            if (subject.user != "erebor-sysd") return;
            ${lib.optionalString (allowed "set-power-profile") ''
              if (action.id == "org.freedesktop.UPower.PowerProfiles.switch-profile") return polkit.Result.YES;
            ''}
            ${lib.optionalString (allowed "sleep") ''
              if (action.id == "org.freedesktop.login1.suspend" ||
                  action.id == "org.freedesktop.login1.suspend-multiple-sessions") return polkit.Result.YES;
            ''}
            ${lib.optionalString (allowed "power-off") ''
              if (action.id == "org.freedesktop.login1.power-off" ||
                  action.id == "org.freedesktop.login1.power-off-multiple-sessions") return polkit.Result.YES;
            ''}
            ${lib.optionalString (allowed "reboot-windows") ''
              if (action.id == "org.freedesktop.systemd1.manage-units" &&
                  action.lookup("unit") == "${cfg.rebootWindowsUnit}" &&
                  action.lookup("verb") == "start") return polkit.Result.YES;
            ''}
          });
        '';

        environment.systemPackages = [ cli ];
      };
    };
}

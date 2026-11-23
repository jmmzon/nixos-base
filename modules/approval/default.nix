# approvald: one daemon that holds the approval credentials and asks the user
# to approve a request through the methods a host enables (phone passkey,
# security key, Mac SSH agent, desktop notification). Callers (sudo's PAM
# step, a control daemon) ask it over a group-restricted socket; it answers
# approved, denied, timeout or failed. docs/approval-protocol.md describes the
# design and the protocol.
{ lib, ... }:
let
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./run.py
      (lib.fileset.difference ./approvald ./approvald/tests)
    ];
  };
  testSrc = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./run.py
      ./approvald
    ];
  };
in
{
  perSystem =
    { pkgs, ... }:
    {
      # Unit tests: policy, challenge binding, outcomes, signature checks.
      checks.approval-unit =
        pkgs.runCommand "approval-unit"
          {
            nativeBuildInputs = [
              (pkgs.python3.withPackages (p: [
                p.cryptography
                p.fido2
                p.pytest
                p.webauthn
              ]))
            ];
          }
          ''
            cp -r ${testSrc} src && chmod -R u+w src && cd src
            python3 -m pytest -q -p no:cacheprovider approvald/tests
            touch $out
          '';
    };

  flake.modules.nixos.approval =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.my.approval;
      m = cfg.methods;
      domain = config.my.network.domain;
      web = config.my.services.phone-approval;
      # Only a host with the phone method needs a domain.
      rpId = if m.phone.enable then "${web.publicName}.${domain}" else null;

      daemonPython = pkgs.python3.withPackages (p: [
        p.cryptography
        p.fido2
        p.webauthn
      ]);
      agentPython = pkgs.python3.withPackages (p: [ p.fido2 ]);
      clientPython = pkgs.python3.withPackages (p: [ p.fido2 ]);

      macSocket = "/run/mac-approval/${cfg.user}/agent.sock";
      methodSettings = {
        phone = {
          inherit (m.phone) enable delivery allowHighRisk;
          kdeconnectDevice = m.phone.kdeconnectDevice;
          inherit rpId;
          port = web.port;
        };
        yubikey = {
          inherit (m.yubikey) enable allowHighRisk;
          rpId = "approvald";
        };
        mac = {
          inherit (m.mac) enable allowHighRisk;
          keysDir = "/etc/security/mac-approval";
          socket = macSocket;
        };
        desktop = { inherit (m.desktop) enable allowHighRisk; };
        fake = {
          inherit (m.fake)
            enable
            answer
            delay
            strength
            allowHighRisk
            ;
          inherit (m.fake) answerFile;
          type = "fake";
        };
      };
      enabledMethods = lib.attrNames (lib.filterAttrs (_: s: s.enable) methodSettings);

      callers =
        cfg.callers
        // lib.optionalAttrs cfg.pam.sudo.enable {
          sudo = {
            users = [ "root" ];
            groups = [ ];
            methods = cfg.pam.sudo.methods;
            rateLimit = {
              burst = 3;
              perMinute = 6;
            };
          };
        };

      configFile = pkgs.writeText "approvald.json" (
        builtins.toJSON {
          inherit (cfg)
            user
            defaultTimeout
            maxTimeout
            onDeny
            testing
            ;
          host = config.networking.hostName;
          methods = methodSettings;
          inherit callers;
        }
      );

      run = python: role: "${python}/bin/python3 -I ${src}/run.py ${role}";

      cli = pkgs.writeShellScriptBin "approval" ''
        export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
        export APPROVAL_YUBIKEY_RP_ID=approvald
        exec ${run clientPython "cli"} "$@"
      '';
      fake = pkgs.writeShellScriptBin "approvald-fake" ''
        exec ${run pkgs.python3 "fake"} "$@"
      '';
      # Bounded like the Mac step: a stuck helper can't hold up the stack.
      pamStep = pkgs.writeShellScript "approval-pam" ''
        export APPROVAL_USER=${lib.escapeShellArg cfg.user}
        export APPROVAL_PAM_METHODS=${lib.escapeShellArg (lib.concatStringsSep "," cfg.pam.sudo.methods)}
        export APPROVAL_PAM_TIMEOUT=${toString cfg.pam.sudo.timeout}
        exec ${pkgs.coreutils}/bin/timeout --kill-after=2s ${toString (cfg.pam.sudo.timeout + 8)}s \
          ${run pkgs.python3 "pam"} </dev/null
      '';

      # The session agent is needed by every method but fake.
      needsAgent = lib.any (n: n != "fake") enabledMethods;

      methodOpts =
        name: highRisk: extra:
        {
          enable = lib.mkEnableOption "the ${name} approval method";
          allowHighRisk = lib.mkOption {
            type = lib.types.bool;
            default = highRisk;
            description = "Whether ${name} may approve requests marked high risk.";
          };
        }
        // extra;
    in
    {
      imports = [
        (lib.mkRenamedOptionModule
          [ "my" "phoneApproval" "enable" ]
          [ "my" "approval" "methods" "phone" "enable" ]
        )
        (lib.mkRenamedOptionModule
          [ "my" "phoneApproval" "device" ]
          [ "my" "approval" "methods" "phone" "kdeconnectDevice" ]
        )
        (lib.mkRenamedOptionModule
          [ "my" "phoneApproval" "timeout" ]
          [ "my" "approval" "pam" "sudo" "timeout" ]
        )
      ];

      options.my.approval = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = enabledMethods != [ ];
          defaultText = lib.literalExpression "any method enabled";
          description = "The approval daemon (approvald); on when any method is.";
        };
        user = lib.mkOption {
          type = lib.types.str;
          default = config.my.user.name;
          defaultText = lib.literalExpression "config.my.user.name";
          description = "The user who approves. Callers can't choose another.";
        };
        defaultTimeout = lib.mkOption {
          type = lib.types.ints.between 5 600;
          default = 60;
          description = "Seconds a request waits when the caller names no timeout.";
        };
        maxTimeout = lib.mkOption {
          type = lib.types.ints.between 5 600;
          default = 300;
          description = "Longest wait a caller may ask for.";
        };
        onDeny = lib.mkOption {
          type = lib.types.enum [
            "deny"
            "continue"
          ];
          default = "deny";
          description = ''
            What a "Deny" from one method does while others still wait: `deny`
            refuses the request at once; `continue` lets another method still
            approve it (the request is denied if none does).
          '';
        };
        testing = lib.mkOption {
          type = lib.types.bool;
          default = false;
          internal = true;
          description = "Allow the fake method. VM tests only.";
        };

        methods = {
          phone = methodOpts "phone (passkey on a one-time page)" true {
            delivery = lib.mkOption {
              type = lib.types.listOf (
                lib.types.enum [
                  "kdeconnect"
                  "notification"
                  "qr"
                ]
              );
              default = [ "kdeconnect" ];
              description = ''
                How the one-time link reaches the phone, all at once: `kdeconnect`
                shares it to the phone, `notification` shows it on the desktop
                (Open), `qr` shows it as a QR code to scan.
              '';
            };
            kdeconnectDevice = lib.mkOption {
              type = lib.types.nullOr (lib.types.strMatching "[A-Za-z0-9_]+");
              default = null;
              example = "0123456789abcdef0123456789abcdef";
              description = "KDE Connect ID of the phone (`kdeconnect-cli -l`), for the `kdeconnect` delivery.";
            };
          };
          yubikey = methodOpts "security key (FIDO2 touch; enroll with `approval enroll yubikey`)" true { };
          mac = methodOpts "Mac (SSH-agent signature over the Mac approval tunnel)" true { };
          desktop =
            methodOpts "desktop notification (weak: any of the user's processes can answer)" false
              { };
          fake = methodOpts "fake (tests only)" true {
            answer = lib.mkOption {
              type = lib.types.enum [
                "approve"
                "deny"
                "fail"
                "timeout"
              ];
              default = "approve";
              description = "The fake method's answer.";
            };
            answerFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "A file (path as a string) whose content overrides `answer` per request.";
            };
            delay = lib.mkOption {
              type = lib.types.int;
              default = 0;
              description = "Seconds before the fake method answers.";
            };
            strength = lib.mkOption {
              type = lib.types.enum [
                "strong"
                "weak"
              ];
              default = "strong";
              description = "How the fake method counts.";
            };
          };
        };

        pam.sudo = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = m.phone.enable;
            defaultText = lib.literalExpression "config.my.approval.methods.phone.enable";
            description = ''
              A sufficient sudo PAM step that asks approvald (after the Mac step,
              before the security key and the password, which keep working).
            '';
          };
          methods = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "phone" ];
            description = "Methods the sudo step may use (pam_rssh and pam_u2f stay separate PAM steps).";
          };
          timeout = lib.mkOption {
            type = lib.types.ints.between 5 120;
            default = 30;
            description = "Seconds sudo waits for an approval before trying the next method.";
          };
        };

        callers = lib.mkOption {
          default = { };
          description = ''
            Who may ask for approvals, by the peer's user or group, and which
            methods each may use at most. A request's own `methods` narrow this.
          '';
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                users = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "Users (the peer's uid) that are this caller.";
                };
                groups = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "Groups (the peer's primary or supplementary group) that are this caller; uids are matched first.";
                };
                methods = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  description = "Methods this caller may use.";
                };
                rateLimit = {
                  burst = lib.mkOption {
                    type = lib.types.ints.positive;
                    default = 3;
                    description = "Requests allowed at once.";
                  };
                  perMinute = lib.mkOption {
                    type = lib.types.ints.positive;
                    default = 6;
                    description = "Requests per minute after the burst.";
                  };
                };
              };
            }
          );
        };
      };

      config = lib.mkMerge [
        {
          # Kept under its old name: the Caddy site, port and passkeys stay.
          my.services.phone-approval = {
            port = 18097;
            publicName = "approve";
            # The approval pages are for the tailnet and LAN only.
            extraConfig = ''
              @phone_approval_outside not remote_ip private_ranges 100.64.0.0/10 fd7a:115c:a1e0::/48
              respond @phone_approval_outside 403
            '';
          };
        }
        (lib.mkIf cfg.enable {
          assertions = [
            {
              assertion = m.fake.enable -> cfg.testing;
              message = "my.approval.methods.fake is for VM tests only.";
            }
            {
              assertion =
                (m.phone.enable && lib.elem "kdeconnect" m.phone.delivery) -> m.phone.kdeconnectDevice != null;
              message = "my.approval.methods.phone.kdeconnectDevice is needed for the kdeconnect delivery: the phone's KDE Connect ID (`kdeconnect-cli -l`).";
            }
            {
              assertion = m.mac.enable -> config.my.macApproval.enable;
              message = "my.approval.methods.mac needs my.macApproval (the tunnel and the provisioned keys).";
            }
          ]
          ++ lib.mapAttrsToList (name: c: {
            assertion = lib.all (x: lib.elem x enabledMethods) c.methods;
            message = "my.approval callers.${name}: methods ${toString c.methods}, enabled are ${toString enabledMethods}.";
          }) callers;

          my.services.phone-approval.enable = m.phone.enable;

          users.groups.approvald = { };
          users.groups.approval-clients = { };
          users.users =
            # The request socket is group-restricted: callers named by user join it.
            lib.genAttrs (lib.remove "root" (lib.unique (lib.concatMap (c: c.users) (lib.attrValues callers))))
              (_: {
                extraGroups = [ "approval-clients" ];
              })
            // {
              approvald = {
                isSystemUser = true;
                group = "approvald";
              };
            };

          systemd.sockets.approvald-request = {
            description = "Approval requests";
            wantedBy = [ "sockets.target" ];
            socketConfig = {
              ListenStream = "/run/approvald/request.sock";
              SocketMode = "0660";
              SocketGroup = "approval-clients";
              FileDescriptorName = "request";
              Service = "approvald.service";
            };
          };
          # Any user may connect; the daemon accepts only my.approval.user's agent.
          systemd.sockets.approvald-agent = {
            description = "Approval session agent";
            wantedBy = [ "sockets.target" ];
            socketConfig = {
              ListenStream = "/run/approvald/agent.sock";
              SocketMode = "0666";
              FileDescriptorName = "agent";
              Service = "approvald.service";
            };
          };

          systemd.services.approvald = {
            description = "Approval daemon";
            # Started at boot too: the phone pages listen on their own port.
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            requires = [
              "approvald-request.socket"
              "approvald-agent.socket"
            ];
            environment.APPROVALD_CONFIG = configFile;
            serviceConfig = {
              ExecStart = run daemonPython "daemon";
              # Passkeys enrolled with the old phone-approval service move over once.
              ExecStartPre = "+${pkgs.writeShellScript "approvald-migrate" ''
                old=/var/lib/private/phone-approval/credentials.json
                new=/var/lib/approvald/phone.json
                if [ -s "$old" ] && [ ! -e "$new" ]; then
                  ${pkgs.coreutils}/bin/install -o approvald -g approvald -m 0600 "$old" "$new"
                fi
              ''}";
              Sockets = [
                "approvald-request.socket"
                "approvald-agent.socket"
              ];
              User = "approvald";
              Group = "approvald";
              StateDirectory = "approvald";
              StateDirectoryMode = "0700";
              Restart = "on-failure";
              UMask = "0077";
              NoNewPrivileges = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              PrivateDevices = true;
              PrivateIPC = true;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectKernelLogs = true;
              ProtectControlGroups = true;
              ProtectClock = true;
              ProtectHostname = true;
              ProtectProc = "invisible";
              ProcSubset = "pid";
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
                "AF_INET6"
              ];
              IPAddressAllow = "localhost";
              IPAddressDeny = "any";
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

          systemd.user.services.approval-agent = lib.mkIf needsAgent {
            description = "Approval agent (notifications, phone links, security key, Mac)";
            wantedBy = [ "graphical-session.target" ];
            partOf = [ "graphical-session.target" ];
            after = [ "graphical-session.target" ];
            unitConfig.ConditionUser = cfg.user;
            environment.QT_QPA_PLATFORM = "offscreen"; # kdeconnect-cli needs no display
            path = [
              pkgs.libnotify
              pkgs.qrencode
              pkgs.xdg-utils
              pkgs.kdePackages.kdeconnect-kde
            ];
            serviceConfig = {
              ExecStart = run agentPython "agent";
              Restart = "always";
              RestartSec = 3;
            };
          };

          security.pam.services.sudo.rules.auth.approval = lib.mkIf cfg.pam.sudo.enable {
            # After the Mac step (10700) and before the YubiKey (10900).
            # Sufficient: a refusal or timeout continues down the stack.
            order = config.security.pam.services.sudo.rules.auth.rssh.order + 100;
            control = "sufficient";
            modulePath = "${pkgs.pam}/lib/security/pam_exec.so";
            args = [
              "quiet"
              "seteuid"
              (toString pamStep)
            ];
          };

          environment.systemPackages = [
            cli
            fake
          ];
        })
      ];
    };
}

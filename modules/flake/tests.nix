# Eval tests: the design rules from AGENTS.md, checked against the template
# host by `nix flake check` (checks.x86_64-linux.eval-<name>). Each test is a
# list of failure messages; an empty list passes. Nothing here is built into a
# system, so the tests cost evaluation time only. A private flake that builds
# real hosts from these aspects runs the same rules against them.
{
  config,
  inputs,
  lib,
  ...
}:
let
  inherit (config.flake.modules) nixos;
  hosts = config.flake.nixosConfigurations;
  template = hosts.template.config;

  check = cond: message: lib.optional (!cond) message;
  unitNames = cfg: lib.attrNames cfg.systemd.services ++ lib.attrNames cfg.systemd.user.services;
  sessionNames = cfg: map (p: lib.getName p) cfg.services.displayManager.sessionPackages;

  # Units that exist only when their optional feature is on.
  featureUnits = [
    "hyperhdr"
    "moonshine"
    "sunshine"
    "ollama"
    "open-webui"
    "searx"
    "samba-smbd"
    "t3code"
    "podman-jellyfin"
    "podman-nextcloud"
    "podman-qbittorrent"
    "podman-syncthing"
  ];

  # A config whose `my.*` is wrong in one way must fail with a message naming
  # the setting.
  extendedWith = module: (hosts.template.extendModules { modules = [ module ]; }).config;
  failedWith =
    module:
    let
      cfg = (hosts.template.extendModules { modules = [ module ]; }).config;
    in
    map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);
  mentions = needle: messages: lib.any (lib.hasInfix needle) messages;

  # The template on aarch64-linux: no shared aspect may hard-code an x86_64
  # package or input.
  templateAarch64 = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [ nixos.template ];
  };

  tests = {
    # Oo7 is the desktop Secret Service; GNOME Keyring and KWallet stay off.
    secret-service =
      check template.services.oo7.enable "template: services.oo7.enable is off"
      ++ check (!template.services.gnome.gnome-keyring.enable) "template: GNOME Keyring is enabled"
      ++ check (lib.all (s: !(s.kwallet.enable or false)) (
        lib.attrValues template.security.pam.services
      )) "template: a PAM service unlocks KWallet";

    # Umbriel is the only session unless my.hyprland adds Hyprland.
    sessions =
      check (sessionNames template == [ "umbriel" ]) "template: sessions are not exactly [ umbriel ]"
      ++ check (
        sessionNames (extendedWith {
          my.hyprland.enable = true;
        }) == [
          "umbriel"
          "hyprland"
        ]
      ) "template with my.hyprland: sessions are not exactly [ umbriel hyprland ]";

    # Optional features switch off: the template enables none of them.
    features-off =
      map (u: "template: unit ${u} exists although its feature is off") (
        lib.intersectLists (unitNames template) featureUnits
      )
      ++ check (!template.my.ambilight.enable) "template: my.ambilight is on"
      ++ map (n: "template: my.services.${n} is enabled") (
        lib.attrNames (lib.filterAttrs (_: s: s.enable) template.my.services)
      );

    # Home Manager manages the main user.
    home-manager = check (lib.elem template.my.user.name (lib.attrNames template.home-manager.users)) "template: no Home Manager config for my.user.name";

    # The my.* assertions fire, naming the setting to fix.
    my-assertions =
      check (mentions "my.ambilight.musicSink" (failedWith {
        my.ambilight.enable = true;
      })) "ambilight without musicSink is not reported"
      ++ check (mentions "my.nanokvm.url" (failedWith {
        my.nanokvm.enable = true;
      })) "nanokvm without url is not reported"
      ++ check (mentions "loopback port" (failedWith {
        my.services.jellyfin.enable = true;
        my.services.syncthing = {
          enable = true;
          port = lib.mkForce template.my.services.jellyfin.port;
        };
      })) "two services on one port are not reported"
      ++ check (failedWith { } == [ ]) "the template itself fails an assertion";

    # The template's system derivation instantiates: a shared module that needs
    # something the template lacks (a secrets file, hardware) fails here, which
    # evaluating the template's options alone does not show.
    template-instantiates = check (builtins.tryEval hosts.template.config.system.build.toplevel.drvPath).success "template: system.build.toplevel does not evaluate (run nix eval .#nixosConfigurations.template.config.system.build.toplevel.drvPath)";

    # Noctalia's Umbriel theme hook (apply.sh) moves "noctalia.toml" to the end
    # of include.optional.files on every theme apply; with any other order a
    # live copy of home/umbriel/config.toml would be edited behind the user's
    # back (SYS-124).
    umbriel-include-order =
      let
        files =
          (builtins.fromTOML (builtins.readFile ../../home/umbriel/config.toml)).include.optional.files;
      in
      check (files != [ ] && lib.last files == "noctalia.toml")
        "home/umbriel/config.toml: \"noctalia.toml\" must be the last include.optional entry (Noctalia's theme hook moves it there); add new includes before it";

    # The template instantiates on aarch64-linux too, and no shared aspect
    # hard-codes an x86_64-linux package into it.
    template-aarch64 =
      let
        vm = templateAarch64.config;
        hm = vm.home-manager.users.${vm.my.user.name};
        packages = vm.environment.systemPackages ++ hm.home.packages ++ [ hm.qt.style.package ];
        foreign = lib.filter (p: (p.system or "aarch64-linux") != "aarch64-linux") packages;
      in
      check (builtins.tryEval vm.system.build.toplevel.drvPath).success "template (aarch64-linux): system.build.toplevel does not evaluate"
      ++ map (p: "template (aarch64-linux): ${p.name or "?"} is built for ${p.system}") foreign;
  };
in
{
  perSystem =
    { pkgs, ... }:
    {
      checks = lib.mapAttrs' (
        name: failures:
        lib.nameValuePair "eval-${name}" (
          pkgs.runCommand "eval-${name}" { } (
            if failures == [ ] then
              "touch $out"
            else
              ''
                cat >&2 <<'EOF'
                eval test ${name} failed:
                ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failures}
                EOF
                exit 1
              ''
          )
        )
      ) tests;
    };
}

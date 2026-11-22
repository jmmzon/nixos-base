# Starting point for a machine built from these aspects. In a flake that
# takes this one as an input (`nixos-base`), copy this folder to
# modules/hosts/<name>, take the aspects from inputs.nixos-base.modules.nixos
# instead of config.flake.modules, replace _hardware-configuration.nix with
# the machine's (nixos-generate-config), rename `template` below to the host's
# name, and adjust the values.
{ config, inputs, ... }:
let
  inherit (config.flake.modules) nixos;
in
{
  # Evaluated, never deployed: proves the optional features switch off.
  flake.nixosConfigurations.template = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ nixos.template ];
  };

  flake.modules.nixos.template =
    { ... }:

    {
      imports = with nixos; [
        ./_hardware-configuration.nix
        workstation
        # Optional hardware-specific aspects:
        # xremap          # set my.xremap.devices
        # nvidia
        # looking-glass   # Looking Glass client for a `windows11` libvirt VM
      ];

      networking.hostName = "template";

      my = {
        user = {
          name = "user";
          description = "User";
        };
        # secretsFile = ../../../secrets/template.yaml; # sops-encrypted
        # flakePath = "/etc/nixos"; # live desktop configs from this checkout
        network = {
          domain = "template.example.com";
          lanInterface = "enp1s0";
          # ovhDns.enable = true;              # needs ovh_* in my.secretsFile
        };
        # Everything below defaults to off; enable what this machine has.
        # ambilight = {
        #   enable = true;
        #   musicSink = "alsa_output.…";
        #   wledUrl = "http://192.168.1.x";
        # };
        # yubikey = { enable = true; lockOnRemoval = true; };
        # sequoiaWallpaper = { enable = true; }; # needs ~/.local/share/sequoia/sequoia.scene
        # liquidGlass = { enable = true; };      # Umbriel, lock screen and greeter glass
        # modes = { enable = true; powerSaver.brightnessConnectors = [ "DP-1" ]; }; # power-saver dims the desktop
        # macApproval = { enable = true; };
        # nanokvm = { enable = true; url = "https://<kvm-name>:8443"; };
        # torrentVpn = { enable = true; };       # qBittorrent only via Proton VPN
        # updateBranch = { enable = true; script = ./update-branch; }; # weekly tested flake update branch
        # streaming = {
        #   sunshine.enable = true;              # also serves sunshine.<domain>
        #   moonshine.enable = true;
        # };
        # Web services: each adds its routes, /etc/hosts name and LAN port
        # (see modules/services and my.services in modules/my.nix).
        # services = {
        #   jellyfin.enable = true;
        #   nextcloud.enable = true;
        #   syncthing.enable = true;
        #   qbittorrent.enable = true;
        #   ollama.enable = true;                # needs an NVIDIA GPU
        #   t3code.enable = true;
        #   cockpit.enable = true;
        # };
      };

      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;

      system.stateVersion = "26.05";
    };
}

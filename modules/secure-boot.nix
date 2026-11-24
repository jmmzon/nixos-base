# UEFI Secure Boot with Lanzaboote (my.secureBoot). Lanzaboote installs its own
# signed systemd-boot and one signed unified kernel image (kernel, initrd and
# command line) per generation, so the command line cannot be edited at boot.
# systemd-boot lists Windows itself when its loader is on the same ESP.
# Enrolment is manual: `sbctl create-keys`, switch, clear the keys in the
# firmware (setup mode), `sbctl enroll-keys --microsoft` (Microsoft's keys
# sign GPU option ROMs and Windows), then turn Secure Boot on.
{ inputs, ... }:
{
  flake.modules.nixos.secure-boot =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [ inputs.lanzaboote.nixosModules.lanzaboote ];
      config = lib.mkIf config.my.secureBoot.enable {
        boot.lanzaboote = {
          enable = true;
          inherit (config.my.secureBoot) pkiBundle;
        };
        # Lanzaboote replaces these loaders.
        boot.loader.systemd-boot.enable = lib.mkForce false;
        boot.loader.grub.enable = lib.mkForce false;
        environment.systemPackages = [ pkgs.sbctl ];
      };
    };
}

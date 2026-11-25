# Everything a desktop built on this flake shares. Hosts import this aspect, add
# their hardware, and set the my.* options (see modules/my.nix).
{ config, ... }:
let
  inherit (config.flake.modules) nixos;
in
{
  flake.modules.nixos.workstation = {
    imports = with nixos; [
      base
      kmscon
      session
      keyring
      ssh
      caddy
      packages
      my
      ambilight
      boot-timing
      erebor-modes
      headphone-eq
      mac-approval
      approval
      control-daemon
      sudo-polkit-fallback
      spotify
      sunshine
      remote-desktop
      browser-desktop
      browser-terminal
      steam-theme
      jellyfin
      syncthing
      qbittorrent
      proton-vpn-bridge
      nextcloud
      ollama
      t3code
      cockpit
      timemachine
      desktop
      # Formerly added to every host by flake.nix.
      moonshine
      noctalia
      sequoia-wallpaper
      shader-wallpaper
      lockscreen-glass
      noctalia-hdr-screenshot
      noctalia-bar-idle-dim
      greeter-glass
      plymouth-greeter-handoff
      umbriel
      dashboard-control
      vicinae
      darkly
      home-manager
      update-branch
      secrets
      secure-boot
    ];
    # On only through nixpkgs' graphical-desktop default; its eSpeak NG pulls
    # every MBROLA voice (0.7 GB). Browsers and Qt link their own minimal
    # libspeechd, so read-aloud just has no system voices (SYS-097).
    services.speechd.enable = false;
  };
}

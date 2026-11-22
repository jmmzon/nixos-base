# Graphical session plumbing: portals, audio and Helium. The greeter,
# compositors and shell live in their own aspects (noctalia, umbriel).
{ inputs, ... }:
{
  flake.modules.nixos.session =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      user = config.my.user.name;
    in
    {
      imports = [ inputs.helium.nixosModules.default ];

      # Helium writes CHROME_WRAPPER into the Exec= line of web-app
      # launchers; upstream sets it to the versioned store path, which a
      # garbage collection removes after an update. Point it at the stable
      # system profile instead ($HERE still comes from the real path).
      # An overlay so a host can still .override it (e.g. fetchurl).
      nixpkgs.overlays = [
        (final: _: {
          helium-stable-wrapper = (final.callPackage "${inputs.helium}/helium.nix" { }).overrideAttrs (old: {
            postInstall = (old.postInstall or "") + ''
              substituteInPlace $out/opt/helium/helium-wrapper \
                --replace-fail 'export CHROME_WRAPPER' \
                  'CHROME_WRAPPER=/run/current-system/sw/bin/helium; export CHROME_WRAPPER'
            '';
          });
        })
      ];

      systemd.user.services.xdg-desktop-portal = {
        after = [
          "graphical-session.target"
          "xdg-desktop-portal-gnome.service"
        ];
        wants = [ "xdg-desktop-portal-gnome.service" ];
        # The host app registry resolves desktop-file Exec= commands via PATH;
        # without the system/user profiles it rejects apps like vicinae.
        path = [
          "/run/current-system/sw"
          "/etc/profiles/per-user/${user}"
        ];
      };

      services.pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
        wireplumber.enable = true;
        extraConfig.client."90-hyperhdr-music" = lib.mkIf config.my.ambilight.enable {
          "stream.rules" = [
            {
              matches = [
                {
                  "application.process.binary" = ".hyperhdr-wrapped";
                  "media.class" = "Stream/Input/Audio";
                }
              ];
              actions.update-props = {
                "target.object" = config.my.ambilight.musicSink;
                "stream.capture.sink" = true;
              };
            }
          ];
        };
      };

      xdg.portal = {
        enable = true;
        extraPortals = [
          pkgs.oo7-portal
          pkgs.xdg-desktop-portal-gnome
          pkgs.xdg-desktop-portal-gtk
        ];
      };

      programs.helium = {
        enable = true;
        flags = [ "--password-store=gnome-libsecret" ];
        package = lib.mkDefault pkgs.helium-stable-wrapper;
      };
    };
}

{
  flake.modules.nixos.jellyfin =
    { config, lib, ... }:
    {
      config = lib.mkMerge [
        {
          my.services.jellyfin = {
            port = 18096;
            localName = "jellyfin";
            publicName = "media";
            lanPort = 8096;
          };
        }
        (lib.mkIf config.my.services.jellyfin.enable {
          virtualisation.oci-containers.backend = "podman";
          virtualisation.oci-containers.containers.jellyfin = {
            image = "docker.io/jellyfin/jellyfin:10.11.11";
            ports = [ "127.0.0.1:18096:8096" ];
            volumes = [
              "/srv/jellyfin/config:/config"
              "/srv/jellyfin/cache:/cache"
              "/srv/torrents/complete:/media:ro"
            ]
            ++ map (d: "/srv/external/${d}:/media-external/${d}:ro") config.my.externalDrives.names;
            environment = {
              TZ = "Europe/Warsaw";
              JELLYFIN_PublishedServerUrl = "http://${config.networking.hostName}:8096";
            };
            extraOptions = [ "--user=1000:1000" ];
          };
        })
      ];
    };
}

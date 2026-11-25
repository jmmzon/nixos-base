# Media libraries: folders on other drives shown inside the user's XDG folders.
# For each kind (Videos, Music, ...) and each named source, ~/<kind>/Library/<name>
# is a bind mount of that source, and ~/<kind>/Library/All a mergerfs union of
# every source of that kind. All mounts are automounts and nofail, so a missing
# drive only leaves its folder empty (mergerfs skips a source that is not there,
# and never creates it on the disk underneath).
{
  flake.modules.nixos.media-library =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.my.mediaLibrary;
      user = config.my.user.name;
      account = config.users.users.${user};
      kinds = lib.filterAttrs (_: sources: sources != { }) cfg;
      libraryDir = kind: "${account.home}/${kind}/Library";

      bindMounts =
        kind: sources:
        lib.mapAttrs' (
          name: source:
          lib.nameValuePair "${libraryDir kind}/${name}" {
            device = source;
            fsType = "none";
            options = [
              "bind"
              "nofail"
              "x-systemd.automount"
              "x-systemd.requires-mounts-for=${source}"
            ];
          }
        ) sources;

      unionMount = kind: sources: {
        "${libraryDir kind}/All" = {
          device = lib.concatStringsSep ":" (lib.attrValues sources);
          fsType = "fuse.mergerfs";
          options = [
            # A new file goes to the source that already has its folder; a new
            # top-level folder to the source with the most free space.
            "category.create=epmfs"
            "minfreespace=50G"
            "moveonenospc=true"
            # Some players mmap their files, which needs page caching.
            "cache.files=partial"
            "fsname=${lib.toLower kind}-library"
            "nofail"
            "x-systemd.automount"
          ]
          ++ map (source: "x-systemd.wants-mounts-for=${source}") (lib.attrValues sources);
        };
      };
    in
    {
      options.my.mediaLibrary = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
        default = { };
        example = {
          Videos = {
            Media = "/srv/external/media/Videos";
            Backup = "/srv/external/backup/Videos";
          };
          Music.Media = "/srv/external/media/Music";
        };
        description = ''
          Library folders per XDG folder name: each source appears at
          ~/<kind>/Library/<name> (a bind mount) and all sources of a kind
          together at ~/<kind>/Library/All (mergerfs).
        '';
      };

      config = lib.mkIf (kinds != { }) {
        assertions = lib.mapAttrsToList (kind: sources: {
          assertion = !(sources ? All);
          message = "my.mediaLibrary.${kind}: \"All\" is the combined view; give that source another name.";
        }) kinds;

        system.fsPackages = [ pkgs.mergerfs ];

        # Library folders belong to the user; systemd would create them root-owned.
        systemd.tmpfiles.rules = map (kind: "d ${libraryDir kind} 0755 ${user} ${account.group} -") (
          lib.attrNames kinds
        );

        fileSystems = lib.mkMerge (
          lib.mapAttrsToList (kind: sources: bindMounts kind sources // unionMount kind sources) kinds
        );
      };
    };
}

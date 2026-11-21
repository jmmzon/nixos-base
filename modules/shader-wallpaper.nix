# Live "shader:" wallpaper: Noctalia patched to run Shadertoy-style GLSL shaders
# as a wallpaper (single pass, channel images, buffer passes, KDE Shader
# Wallpaper's window inputs), with [wallpaper.shader] settings in
# home/noctalia/config.toml, a pause behind windows (pause_when_covered) and the
# noctalia-shader-thumbnail tool. The picker is the janzon/live-wallpaper plugin
# (home/noctalia/plugins/live-wallpaper).
# Source: ~/src/noctalia-sequoia, branch shader-live, stacked on sequoia-live;
# the patch is `git format-patch --stdout sequoia-live..shader-live`. It needs
# the sequoia patch and applies right after it; the lock screen glass patch is
# stacked on top of it. Design: docs/shader-wallpaper-design.md in that repo.
#
# my.shaderWallpaper.kdeLibrary installs KDE Shader Wallpaper's shaders (pinned)
# to share/noctalia/shaders/kde, where Noctalia and the picker find them through
# XDG_DATA_DIRS. Each shader credits its Shadertoy author and most are under
# Shadertoy's default CC BY-NC-SA 3.0: fine for this machine, not for
# redistribution.
{
  flake.modules.nixos.shader-wallpaper =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.my.shaderWallpaper;
      kdeShaderLibrary = pkgs.stdenvNoCC.mkDerivation {
        pname = "kde-shader-wallpaper-library";
        version = "4.2.4-unstable-2026-11-04";
        src = pkgs.fetchFromGitHub {
          owner = "y4my4my4m";
          repo = "kde-shader-wallpaper";
          rev = "f9eed3d2f6d73f0a5c7e20ef00072be062f1d4bf";
          hash = "sha256-omw4aLHRszS6QRSlKYfuIp0aUUn0RgZ/zm7uPDot5do=";
        };
        nativeBuildInputs = [ pkgs.jq ];
        dontConfigure = true;
        dontBuild = true;
        # Only the shaders, their images and the index: no QML or C++ plugin code.
        installPhase = ''
          runHook preInstall
          dest=$out/share/noctalia/shaders/kde
          mkdir -p "$dest"
          cp -r package/contents/ui/Shaders package/contents/ui/Resources package/contents/ui/shader_index.json "$dest"/
          # A slim copy of the index with only what the live-wallpaper picker reads: a
          # quarter of the size, so its panel opens within the plugin CPU budget.
          jq -c '{shaders: [.shaders[] | {name, category, author, shaderPath, hasBuffers, needsAudio, needsTextures}]}' \
            package/contents/ui/shader_index.json > "$dest/picker_index.json"
          runHook postInstall
        '';
        meta = {
          description = "KDE Shader Wallpaper's shader library, for Noctalia's shader: wallpaper";
          homepage = "https://github.com/y4my4my4m/kde-shader-wallpaper";
          license = lib.licenses.gpl3Plus; # the plugin; the shaders carry their authors' terms
          platforms = lib.platforms.all;
        };
      };
    in
    lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = config.my.sequoiaWallpaper.enable;
          message = "my.shaderWallpaper needs my.sequoiaWallpaper: its patch is stacked on the sequoia patch.";
        }
      ];
      programs.noctalia.patches = lib.mkOrder 1600 [ ../patches/noctalia-shader-wallpaper.patch ];
      environment.systemPackages = lib.optional cfg.kdeLibrary kdeShaderLibrary;
      # The system profile links only listed share/ subdirectories; this one is where
      # Noctalia looks (XDG_DATA_DIRS/noctalia/shaders).
      environment.pathsToLink = lib.optional cfg.kdeLibrary "/share/noctalia/shaders";
    };
}

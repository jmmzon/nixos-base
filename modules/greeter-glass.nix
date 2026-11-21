# Liquid glass under the Noctalia greeter's login panel: the same glass as the
# lock screen (modules/lockscreen-glass.nix) and Umbriel's window backdrop. The
# greeter runs its own compositor, so Umbriel's backdrop patch cannot reach it;
# the patch adds a custom-draw node to the greeter's renderer that copies what
# is drawn under the panel, frosts it and bends it at the rim. Its knobs and flaws
# are Umbriel's glass-window values as the shell's greeter sync staged them
# ([appearance.glass] in sync.toml); without them it keeps the built-in glass.
# Source: ~/src/noctalia-greeter, branch lockscreen-glass on the pinned input
# rev; the patch is `git diff HEAD~4 HEAD -- . ':!1'` there. Re-export on an input bump.
#
# With my.sequoiaWallpaper the greeter also animates the live Sequoia scene on
# outputs whose desktop wallpaper is `sequoia:` (the shell syncs the scene and its
# still's pose into /var/lib/noctalia-greeter; see modules/sequoia-wallpaper.nix).
# It eases into motion, slows after 10 s without input, stops after 30 s and speeds
# up on input. Source: branch sequoia-live on top of lockscreen-glass; the patch is
# `git diff lockscreen-glass sequoia-live -- . ':!1'`. It needs the glass patch.
{
  flake.modules.nixos.greeter-glass =
    { config, lib, ... }:
    lib.mkIf config.my.liquidGlass.enable {
      programs.noctalia.greeterPatches = [
        ../patches/noctalia-greeter-liquid-glass.patch
      ]
      ++ lib.optional config.my.sequoiaWallpaper.enable ../patches/noctalia-greeter-sequoia-live.patch;
    };
}

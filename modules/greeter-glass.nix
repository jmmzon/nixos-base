# Liquid glass under the Noctalia greeter's login panel: the same glass as the
# lock screen (modules/lockscreen-glass.nix) and Umbriel's window backdrop. The
# greeter runs its own compositor, so Umbriel's backdrop effect cannot reach it;
# a greeter fork commit adds a custom-draw node to the greeter's renderer that copies what
# is drawn under the panel, frosts it and bends it at the rim. Its knobs and flaws
# are Umbriel's glass-window values as the shell's greeter sync staged them
# ([appearance.glass] in sync.toml); without them it keeps the built-in glass.
#
# With my.sequoiaWallpaper the greeter also animates the live Sequoia scene on
# outputs whose desktop wallpaper is `sequoia:` (the shell syncs the scene and its
# still's pose into /var/lib/noctalia-greeter; see modules/sequoia-wallpaper.nix).
# It eases into motion, slows after 10 s without input, stops after 30 s and speeds
# up on input.
#
# With my.shaderWallpaper too, it runs the live `shader:` wallpaper the shell
# synced ([appearance.shader] and its wallpaper-shader* files) on the outputs
# showing it, from the still's iTime, with the same idle ramp; compiles run in
# the background while the still stays.
{
  flake.modules.nixos.greeter-glass =
    { config, lib, ... }:
    lib.mkIf config.my.liquidGlass.enable {
    };
}

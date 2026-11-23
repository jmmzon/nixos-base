# Liquid glass under the Noctalia lock screen's login box, its status box and
# the lock-screen widgets that have a background (a port of Umbriel's window
# lens, home/umbriel/effects/liquid-glass-lens.glsl). At each lock it reads the
# glass-window preset (shader defaults, glass.toml params, glass tuner drafts),
# imperfections included, and the greeter sync passes the same values on. Noctalia
# draws the lock as one opaque surface, so the compositor cannot do this: the
# fork commit copies what the lock screen has drawn under each box, frosts it and
# bends it at the rim in Noctalia itself. Desktop widgets are left alone.
# The code is a commit on the noctalia fork's erebor branch.
{
  flake.modules.nixos.lockscreen-glass =
    { config, lib, ... }:
    lib.mkIf
      (
        config.my.liquidGlass.enable
        && config.my.yubikey.enable
        && config.my.sequoiaWallpaper.enable
        && config.my.shaderWallpaper.enable
      )
      {
      };
}

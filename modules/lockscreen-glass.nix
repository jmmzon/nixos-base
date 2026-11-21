# Liquid glass under the Noctalia lock screen's login box, its status box and
# the lock-screen widgets that have a background (a port of Umbriel's window
# lens, home/umbriel/effects/liquid-glass-lens.glsl). At each lock it reads the
# glass-window preset (shader defaults, glass.toml params, glass tuner drafts),
# imperfections included, and the greeter sync passes the same values on. Noctalia
# draws the lock as one opaque surface, so the compositor cannot do this: the
# patch copies what the lock screen has drawn under each box, frosts it and
# bends it at the rim in Noctalia itself. Desktop widgets are left alone.
# Source: ~/src/noctalia-glass, branch lockscreen-glass (on shader-live, which is
# on sequoia-live, plus the security-key patch); the patch is `git diff HEAD~5
# HEAD` there. Its context includes those patches, so it needs them and applies
# after them.
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
        programs.noctalia.patches = lib.mkOrder 2000 [ ../patches/noctalia-lockscreen-liquid-glass.patch ];
      };
}

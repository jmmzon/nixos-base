# Noctalia bar OLED care. The patch adds three [bar.<name>] keys:
# idle_opacity (fade the whole bar, icons and text included, once the pointer
# has been away for idle_delay_ms and no bar popup or attached panel is open;
# hover, an opened panel or a workspace switch brings it back) and pixel_shift
# (drift the bar contents up to N px along the bar and 1 px across it, one step
# every 3 minutes). Values live in home/noctalia/config.toml. It applies to
# upstream Noctalia on its own and last after the other Noctalia patches.
# Source: ~/src/noctalia-bar-dim, branch bar-idle-dim (one commit on a base
# commit holding the erebor patch stack); the patch is `git diff HEAD~1 HEAD`.
{
  flake.modules.nixos.noctalia-bar-idle-dim =
    { lib, ... }:
    {
      programs.noctalia.patches = lib.mkOrder 2200 [ ../patches/noctalia-bar-idle-dim.patch ];
    };
}

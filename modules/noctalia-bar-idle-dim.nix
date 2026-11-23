# Noctalia bar OLED care. A commit on the noctalia fork's erebor branch adds three [bar.<name>] keys:
# idle_opacity (fade the whole bar, icons and text included, once the pointer
# has been away for idle_delay_ms and no bar popup or attached panel is open;
# hover, an opened panel or a workspace switch brings it back) and pixel_shift
# (drift the bar contents up to N px along the bar and 1 px across it, one step
# every 3 minutes). Values live in home/noctalia/config.toml.
{
  flake.modules.nixos.noctalia-bar-idle-dim =
    { lib, ... }:
    {
    };
}

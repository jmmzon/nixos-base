{
  # Shared background opacity for Ghostty, Monstar, Vicinae, Zen and Noctalia's
  # transparent Zed themes, per Noctalia theme mode. Range: 0.0 (transparent)
  # to 1.0 (opaque). The mode switch is modules/home/theme-opacity.nix.
  #
  # The two are matched by eye-equivalent see-through, not by equal numbers:
  # a light pane over the wallpaper needs more opacity than a dark one to let
  # the same amount of the backdrop's contrast (CIELAB L*) through. Measured
  # in a headless compositor with the window glass over two wallpapers (a
  # bright photo and a dark shader); both gave light 0.62 for dark 0.7
  # (dark 0.8 -> light 0.75, dark 0.9 -> light 0.9). Change both together.
  appOpacity = {
    dark = 0.7;
    light = 0.62;
  };
  # Zen's chrome (home/zen/translucent.css), the same in both modes; null
  # follows appOpacity instead.
  zenOpacity = null;
}

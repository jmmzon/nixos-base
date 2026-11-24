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
  # The same see-through match as a curve, "dark light" rows, for Noctalia's
  # surfaces (bar, capsules, OSD, notifications: black in dark mode, a near-
  # white surface in light mode, blended in sRGB like the apps). The mode
  # switch maps a value to a mode it has not seen yet along this curve
  # (linear between points; light to dark the other way round). Measured the
  # same way as appOpacity, from 0.02 to 1: below about 0.6 light needs
  # about 0.82 of the dark value, above 0.8 about the same value.
  seeThrough = ''
    # dark light
    0    0
    0.05 0.041
    0.1  0.082
    0.16 0.131
    0.2  0.163
    0.25 0.204
    0.3  0.245
    0.4  0.33
    0.5  0.419
    0.6  0.514
    0.7  0.621
    0.8  0.747
    0.9  0.902
    0.95 0.96
    1    1
  '';
}

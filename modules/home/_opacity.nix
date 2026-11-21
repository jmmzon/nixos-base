# The shared app opacity from home/appearance.nix, one value per Noctalia theme
# mode, rounded to an 8-bit alpha (Zed's format) so Ghostty, Monstar, Vicinae,
# Zen and Zed use the same value. Not a flake-parts module (the `_` keeps
# import-tree off it); import it with lib.
lib:
let
  appearance = import ../../home/appearance.nix;
  forValue =
    opacity:
    let
      byte =
        assert lib.assertMsg (
          opacity >= 0 && opacity <= 1
        ) "app opacity ${toString opacity} must be between 0 and 1";
        builtins.floor (opacity * 255 + 0.5);
    in
    {
      # As a JSON number between 0 and 1, for Ghostty, Monstar and Vicinae.
      value = builtins.toJSON (byte / 255.0);
      # As two hex digits, for Zed.
      alpha = lib.toUpper (lib.fixedWidthString 2 "0" (lib.toHexString byte));
      # As a whole percentage, for Zen's CSS.
      percent = toString (builtins.floor (opacity * 100 + 0.5));
    };
  forMode = mode: forValue appearance.appOpacity.${mode};
in
{
  dark = forMode "dark";
  light = forMode "light";
  # The same formats for any opacity (reduce transparency raises them, SYS-122).
  inherit forValue;
  inherit (appearance) appOpacity zenOpacity;
  # light / dark: how the switch scales values it has not seen in a mode yet.
  ratio = appearance.appOpacity.light / appearance.appOpacity.dark;
}

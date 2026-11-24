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
  # light / dark: how the switch scales Darkly's values it has not seen in a
  # mode yet.
  ratio = appearance.appOpacity.light / appearance.appOpacity.dark;
  # The see-through curve for Noctalia's surfaces as "dark light dark light ...",
  # checked to rise in both columns from 0 0 to 1 1 (so it maps both ways).
  seeThrough =
    let
      rows = lib.filter (r: r != [ ]) (
        map (line: lib.filter (w: w != "") (lib.splitString " " line)) (
          lib.filter (line: !(lib.hasPrefix "#" (lib.trim line))) (lib.splitString "\n" appearance.seeThrough)
        )
      );
      num = w: builtins.fromJSON w + 0.0;
      col = c: map (r: num (builtins.elemAt r c)) rows;
      rising =
        xs:
        builtins.all (i: builtins.elemAt xs i > builtins.elemAt xs (i - 1)) (
          lib.range 1 (builtins.length xs - 1)
        );
      ends = xs: builtins.head xs == 0.0 && lib.last xs == 1.0;
    in
    assert lib.assertMsg (
      builtins.all (r: builtins.length r == 2) rows
      && ends (col 0)
      && ends (col 1)
      && rising (col 0)
      && rising (col 1)
    ) "appearance.seeThrough: rows of \"dark light\" rising in both columns from 0 0 to 1 1";
    lib.concatMapStringsSep " " (r: lib.concatStringsSep " " r) rows;
}

# my.vmwgfxDmabufFix: rebuild a wlroots compositor (Umbriel, the Noctalia
# greeter's compositor) against wlroots with patches/wlroots-vmwgfx-dmabuf-close.patch.
# Both come from flake inputs, so a nixpkgs overlay would not reach them; this
# swaps the wlroots in their buildInputs instead.
pkgs: drv:
drv.overrideAttrs (old: {
  buildInputs = map (
    input:
    if pkgs.lib.isDerivation input && pkgs.lib.getName input == "wlroots" then
      input.overrideAttrs (w: {
        patches = (w.patches or [ ]) ++ [ ../patches/wlroots-vmwgfx-dmabuf-close.patch ];
      })
    else
      input
  ) (old.buildInputs or [ ]);
})

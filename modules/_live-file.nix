# A repository dotfile for Home Manager: with my.flakePath set, an
# out-of-store link into that checkout (saving the file there applies it
# without a rebuild); with my.flakePath null, the store copy of the same file.
#   liveFile = import ./_live-file.nix { inherit config osConfig; };
#   xdg.configFile."app/config".source = liveFile "home/app/config";
# Not loaded by import-tree (the `_` prefix).
{ config, osConfig }:
rel:
if osConfig.my.flakePath == null then
  ../. + "/${rel}"
else
  config.lib.file.mkOutOfStoreSymlink "${osConfig.my.flakePath}/${rel}"

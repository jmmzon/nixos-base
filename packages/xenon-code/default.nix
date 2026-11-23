# A static four-style coding font cut from Monaspace Xenon's variable font
# (build.py): one family for terminals and editors, with texture healing and
# the ligature sets baked in so apps without font-feature settings match.
{
  lib,
  stdenvNoCC,
  monaspace,
  python3,
}:

let
  family = "Xenon Code";
in
stdenvNoCC.mkDerivation {
  pname = "xenon-code";
  inherit (monaspace) version;

  dontUnpack = true;
  nativeBuildInputs = [ (python3.withPackages (p: [ p.fonttools ])) ];

  buildPhase = ''
    runHook preBuild
    python3 -I ${./build.py} \
      "${monaspace}/share/fonts/truetype/Monaspace Xenon Var.ttf" \
      fonts ${lib.escapeShellArg family}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 -t $out/share/fonts/truetype fonts/*.ttf
    runHook postInstall
  '';

  passthru = { inherit family; };

  meta = {
    description = "Static Monaspace Xenon instances with texture healing and ligatures on by default";
    license = lib.licenses.ofl;
    platforms = lib.platforms.all;
  };
}

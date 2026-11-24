# The jsonline server (./jsonline) as a Python package, for daemons built on
# it (erebor-desktopd): python3.withPackages (ps: [ (ps.callPackage ./_jsonline.nix { }) ]).
{
  python,
  runCommand,
  toPythonModule,
}:
toPythonModule (
  runCommand "python-jsonline" { } ''
    install -Dm644 ${./jsonline/__init__.py} $out/${python.sitePackages}/jsonline/__init__.py
  ''
)

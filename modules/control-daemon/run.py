"""Entry point: run.py sysd|ctl [args]. Run with python -I; the packages are
next to this file in the Nix store."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

role, args = sys.argv[1], sys.argv[2:]
if role == "sysd":
    from sysd.daemon import main

    sys.exit(main(args))
if role == "ctl":
    from sysd.ctl import main

    sys.exit(main(args))
sys.exit(f"unknown role {role}")

"""Entry point: run.py daemon|agent|pam|cli|fake [args]. Run with python -I;
the package is next to this file in the Nix store."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

role, args = sys.argv[1], sys.argv[2:]
if role == "daemon":
    from approvald.daemon import main

    sys.exit(main())
if role == "agent":
    from approvald.agent import main

    sys.exit(main())
if role == "pam":
    from approvald.client import pam_main

    sys.exit(pam_main())
if role == "cli":
    from approvald.client import cli_main

    sys.exit(cli_main(args))
if role == "fake":
    from approvald.fake import main

    sys.exit(main(args))
sys.exit(f"unknown role {role}")

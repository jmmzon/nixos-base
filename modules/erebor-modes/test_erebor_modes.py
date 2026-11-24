"""Tests for erebor-modes: suspend/resume and how Noctalia overrides go back.

The engine runs as a subprocess (it reads its manifest at import) against a
temporary state directory, with a stub `noctalia` on PATH that keeps a config
file and an overrides file (settings.toml) the way Noctalia does: config-get
reads the merged value, config-set writes an override, config-reload re-reads.
"""

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import tomllib
import unittest

ENGINE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "erebor_modes.py")

NOCTALIA_STUB = textwrap.dedent(
    """\
    #!{python}
    import json, os, sys, tomllib
    import tomlkit
    state = os.environ["XDG_STATE_HOME"]
    settings = os.path.join(state, "noctalia", "settings.toml")
    config = os.environ["STUB_CONFIG"]

    def load(p):
        try:
            with open(p, "rb") as f:
                return tomllib.load(f)
        except FileNotFoundError:
            return {{}}

    def get(d, key):
        for part in key.split("."):
            d = d[part]
        return d

    args = sys.argv[2:]
    if args[0] == "config-get":
        try:
            v = get(load(settings), args[1])
        except KeyError:
            v = get(load(config), args[1])
        print(tomlkit.item(v).as_string())
    elif args[0] == "config-set":
        os.makedirs(os.path.dirname(settings), exist_ok=True)
        try:
            doc = tomlkit.parse(open(settings).read())
        except FileNotFoundError:
            doc = tomlkit.document()
        parts = args[1].split(".")
        node = doc
        for p in parts[:-1]:
            node = node.setdefault(p, tomlkit.table())
        node[parts[-1]] = tomllib.loads("v = " + args[2])["v"]
        open(settings, "w").write(tomlkit.dumps(doc))
    elif args[0] == "config-reload":
        pass
    print("ok", file=sys.stderr)
    """
)


class EngineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.state = os.path.join(t, "modes")
        self.xdg_state = os.path.join(t, "xdg-state")
        self.bin = os.path.join(t, "bin")
        os.makedirs(self.bin)
        os.makedirs(os.path.join(self.xdg_state, "noctalia"))
        self.flag = os.path.join(t, "flag")
        self.config = os.path.join(t, "config.toml")
        with open(self.config, "w") as f:
            f.write('[bar.default]\nstart = ["a", "audio_visualizer"]\n[wallpaper]\nmotion = "live"\n')
        stub = os.path.join(self.bin, "noctalia")
        with open(stub, "w") as f:
            f.write(NOCTALIA_STUB.format(python=sys.executable))
        os.chmod(stub, 0o755)
        # powerprofilesctl is absent: the fact falls back to the hook's variable.
        manifest = {
            "modes": [
                {
                    "id": "saver",
                    "label": "Saver",
                    "kind": "toggle",
                    "notify": False,
                    "when": {"toggle": "saver"},
                    "items": [
                        {"id": "flag", "label": "Flag", "handler": "file",
                         "params": {"path": self.flag, "content": "on\n"}},
                        {"id": "visualizer", "label": "Visualizer", "handler": "noctalia-list-remove",
                         "params": {"key": "bar.default.start", "entry": "audio_visualizer"}},
                        {"id": "motion", "label": "Motion", "handler": "noctalia-setting",
                         "params": {"key": "wallpaper.motion", "value": "still"}},
                    ],
                }
            ]
        }
        self.manifest = os.path.join(t, "manifest.json")
        with open(self.manifest, "w") as f:
            json.dump(manifest, f)
        self.env = {
            **os.environ,
            "PATH": self.bin + os.pathsep + os.environ.get("PATH", ""),
            "EREBOR_MODES_MANIFEST": self.manifest,
            "EREBOR_MODES_STATE_DIR": self.state,
            "XDG_STATE_HOME": self.xdg_state,
            "XDG_RUNTIME_DIR": t,  # no daemon socket here: the ping is a no-op
            "STUB_CONFIG": self.config,
        }

    def tearDown(self):
        self.tmp.cleanup()

    def engine(self, *args):
        p = subprocess.run([sys.executable, ENGINE, *args], env=self.env,
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout

    def settings(self):
        try:
            with open(os.path.join(self.xdg_state, "noctalia", "settings.toml"), "rb") as f:
                return tomllib.load(f)
        except FileNotFoundError:
            return {}

    def state_json(self):
        with open(os.path.join(self.state, "state.json")) as f:
            return json.load(f)

    def test_restore_removes_override_it_created(self):
        self.engine("toggle", "saver", "on")
        self.assertEqual(self.settings()["bar"]["default"]["start"], ["a"])
        self.assertEqual(self.settings()["wallpaper"]["motion"], "still")
        self.engine("toggle", "saver", "off")
        # The values came from the config file: the overrides are gone, not copied.
        self.assertEqual(self.settings(), {})
        self.assertFalse(os.path.exists(self.flag))

    def test_restore_keeps_an_override_that_was_there(self):
        subprocess.run(["noctalia", "msg", "config-set", "wallpaper.motion", "'slow'"],
                       env=self.env, check=True, capture_output=True)
        self.engine("toggle", "saver", "on")
        self.engine("toggle", "saver", "off")
        self.assertEqual(self.settings()["wallpaper"]["motion"], "slow")

    def test_suspend_and_resume(self):
        self.engine("toggle", "saver", "on")
        before = self.state_json()
        out = json.loads(self.engine("suspend"))
        self.assertEqual(out["modes"], ["saver"])
        self.assertEqual(sorted(out["restored"]), ["flag", "motion", "visualizer"])
        self.assertFalse(os.path.exists(self.flag))
        self.assertEqual(self.settings(), {})
        # state.json is untouched: the surfaces keep showing the mode.
        self.assertEqual(self.state_json(), before)
        # A sync while suspended (a hook, the game watcher) applies nothing.
        self.engine("sync")
        self.assertFalse(os.path.exists(self.flag))
        # The config file changes meanwhile (a preset switch): resume applies to the new one.
        with open(self.config, "w") as f:
            f.write('[bar.default]\nstart = ["b", "audio_visualizer"]\n[wallpaper]\nmotion = "live"\n')
        self.engine("resume")
        self.assertTrue(os.path.exists(self.flag))
        self.assertEqual(self.settings()["bar"]["default"]["start"], ["b"])
        st = self.state_json()
        self.assertEqual(st["modes"], ["saver"])
        self.assertEqual(st["since"], before["since"])
        self.assertEqual({i: v["status"] for i, v in st["items"].items()},
                         {"flag": "applied", "visualizer": "applied", "motion": "applied"})
        self.engine("toggle", "saver", "off")
        self.assertEqual(self.settings(), {})

    def test_hand_change_survives_suspend_resume(self):
        self.engine("toggle", "saver", "on")
        subprocess.run(["noctalia", "msg", "config-set", "wallpaper.motion", "'slow'"],
                       env=self.env, check=True, capture_output=True)
        out = json.loads(self.engine("suspend"))
        self.assertEqual(out["kept"], ["motion"])
        self.engine("resume")
        self.assertEqual(self.settings()["wallpaper"]["motion"], "slow")
        st = self.state_json()
        self.assertIn("motion", st["overrides"])
        self.assertNotIn("motion", st["items"])

    def test_expired_hold_is_ignored(self):
        self.engine("toggle", "saver", "on")
        self.engine("suspend")
        with open(os.path.join(self.state, "hold.json"), "w") as f:
            json.dump({"until": 0, "overrides": []}, f)
        self.engine("sync")
        self.assertTrue(os.path.exists(self.flag))
        self.assertFalse(os.path.exists(os.path.join(self.state, "hold.json")))


if __name__ == "__main__":
    unittest.main()

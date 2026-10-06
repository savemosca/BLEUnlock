"""Exercise the complete release script with local stand-ins, without signing/uploading."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


STUB = r'''#!/usr/bin/env python3
import json, os, plistlib, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["STUB_LOG"], "a") as log:
    log.write(json.dumps([name, args]) + "\n")
if name == "xcodebuild":
    if "archive" in args:
        Path(args[args.index("-archivePath") + 1]).mkdir(parents=True)
    else:
        export = Path(args[args.index("-exportPath") + 1])
        for app in [export / "BLEUnlock.app", export / "BLEUnlock.app/Contents/Library/LoginItems/Launcher.app"]:
            (app / "Contents").mkdir(parents=True, exist_ok=True)
            with (app / "Contents/Info.plist").open("wb") as file:
                plistlib.dump({"CFBundleShortVersionString": "1.12.2", "CFBundleVersion": "797"}, file)
elif name == "ditto":
    assert len(args) == 5 and args[:3] == ["-c", "-k", "--keepParent"], args
    assert Path(args[3]).is_dir(), args
    Path(args[4]).write_text("test archive")
elif name == "xcrun":
    if args[:2] == ["notarytool", "submit"]:
        assert "--wait" in args and "--timeout" in args, args
        assert args[args.index("--output-format") + 1] == "json", args
        assert Path(args[2]).is_file(), args
        result = os.environ.get("NOTARY_RESULT", "Accepted")
        if result == "Timeout":
            sys.exit(1)
        if result == "Malformed":
            print("not valid JSON")
        else:
            print(json.dumps({"id": "test-id", "status": result}))
    else:
        assert args[:2] == ["stapler", "staple"] and len(args) == 3, args
        assert Path(args[2]).is_dir(), args
'''


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bleunlock-release-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / "Project with spaces"
        self.project.mkdir()
        self.script = self.project / "release"
        shutil.copy2(Path(__file__).resolve().parents[1] / "release", self.script)
        self.bin = self.root / "commands"
        self.bin.mkdir()
        for name in ["xcodebuild", "xcrun", "ditto"]:
            command = self.bin / name
            command.write_text(STUB)
            command.chmod(0o755)
        self.log = self.root / "commands.jsonl"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        STUB_LOG=str(self.log), TEAM="TESTTEAM",
                        NOTARY_PROFILE="Profile with spaces", NOTARY_TIMEOUT="1m")
        self.env.pop("NOTARY_RESULT", None)

    def run_release(self):
        return subprocess.run(["/bin/bash", str(self.script)], cwd=self.root,
                              env=self.env, text=True, capture_output=True, timeout=10)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_success_from_another_directory_with_spaces_in_paths(self):
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        build_args = commands[0][1]
        self.assertEqual(build_args[build_args.index("-project") + 1], str(self.project / "BLEUnlock.xcodeproj"))
        submits = [args for name, args in commands if name == "xcrun" and args[0] == "notarytool"]
        self.assertEqual(len(submits), 2)
        for args in submits:
            self.assertEqual(args[args.index("--timeout") + 1], "1m")
            self.assertEqual(args[args.index("--keychain-profile") + 1], "Profile with spaces")
        self.assertEqual(sum(args[:2] == ["stapler", "staple"] for name, args in commands if name == "xcrun"), 2)
        self.assertTrue((self.project / "build/Release/BLEUnlock-1.12.2.zip").is_file())
        self.assertTrue((self.project / "archives/1.12.2-797/BLEUnlock.xcarchive").is_dir())

    def test_rejection_timeout_and_invalid_response_stop_without_stapling(self):
        for status in ["Invalid", "Timeout", "Malformed"]:
            with self.subTest(status=status):
                self.env["NOTARY_RESULT"] = status
                self.log.write_text("")
                # The mock archive command must accept a second invocation.
                archive = self.project / "build/Release/BLEUnlock.xcarchive"
                if archive.exists():
                    shutil.rmtree(archive)
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                commands = self.commands()
                self.assertFalse(any(args[:2] == ["stapler", "staple"] for name, args in commands if name == "xcrun"))
                self.assertEqual(sum(args[:2] == ["notarytool", "submit"] for name, args in commands if name == "xcrun"), 1)
                self.assertFalse((self.project / "build/Release/BLEUnlock-1.12.2.zip").exists())

    def test_missing_team_fails_before_build(self):
        self.env.pop("TEAM")
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("set TEAM", result.stderr)
        self.assertEqual(self.commands(), [])

    def test_missing_notary_credentials_fails_before_build(self):
        for key in ["NOTARY_PROFILE", "APPLE_ID", "PASSWORD"]:
            self.env.pop(key, None)
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("set NOTARY_PROFILE", result.stderr)
        self.assertEqual(self.commands(), [])


if __name__ == "__main__":
    unittest.main()

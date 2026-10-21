"""Installer tests for the user-level Autonom command."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
INSTALLER = REPOSITORY / "install.py"


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.prefix = Path(tempfile.mkdtemp(prefix="autonom-install-"))
        self.addCleanup(shutil.rmtree, self.prefix, True)
        if not (REPOSITORY / "bin/autonom").is_file():
            self.skipTest("Build the command with dub build --compiler=ldc2 --config=daemon first.")

    def install(self, *arguments):
        return subprocess.run([sys.executable, str(INSTALLER), "--prefix", str(self.prefix),
                               "--no-build", *arguments], capture_output=True, text=True, timeout=60)

    def test_install_creates_the_command_the_runtime_and_the_configuration(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        data = self.prefix / "share/autonom"
        command = self.prefix / "bin/autonom"
        self.assertTrue(command.is_symlink())
        self.assertEqual(command.resolve(), (data / "bin/autonom").resolve())
        self.assertTrue((data / "bin/autonom").is_file())
        self.assertTrue((data / "templates/hook.py").is_file())
        self.assertTrue((data / "templates/hooks.v1.json").is_file())
        self.assertTrue((data / "source/mcp/server.py").is_file())
        config = self.prefix / "config/autonom/config.yml"
        self.assertTrue(config.is_file())
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)

        again = self.install()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("Installed", self.install("--check").stdout)

    def test_install_keeps_an_existing_configuration(self):
        config = self.prefix / "config/autonom/config.yml"
        config.parent.mkdir(parents=True)
        config.write_text("dataDir: /elsewhere\n")
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(config.read_text(), "dataDir: /elsewhere\n")

    def test_install_refuses_to_replace_an_unrelated_command(self):
        command = self.prefix / "bin/autonom"
        command.parent.mkdir(parents=True)
        command.write_text("#!/bin/sh\n")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace an unrelated command", result.stderr)
        self.assertEqual(command.read_text(), "#!/bin/sh\n")

    def test_install_refuses_to_replace_a_foreign_symlink(self):
        command = self.prefix / "bin/autonom"
        command.parent.mkdir(parents=True)
        other = self.prefix / "other"
        other.write_text("other\n")
        os.symlink(other, command)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(command.is_symlink())
        self.assertEqual(command.resolve(), other.resolve())

    def test_uninstall_removes_the_command_and_keeps_user_state(self):
        self.assertEqual(self.install().returncode, 0)
        data = self.prefix / "share/autonom"
        session = data / "sessions.db"
        session.write_text("session\n")
        log = data / "daemon.log"
        log.write_text("log\n")
        config = self.prefix / "config/autonom/config.yml"
        before = config.read_bytes()

        result = self.install("--uninstall")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(os.path.lexists(self.prefix / "bin/autonom"))
        self.assertFalse((data / "bin/autonom").exists())
        self.assertTrue(session.is_file())
        self.assertTrue(log.is_file())
        self.assertEqual(config.read_bytes(), before)

    def test_the_installed_command_reports_its_version(self):
        self.assertEqual(self.install().returncode, 0)
        result = subprocess.run([str(self.prefix / "bin/autonom"), "--version"],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Autonom", result.stdout)


if __name__ == "__main__":
    unittest.main()

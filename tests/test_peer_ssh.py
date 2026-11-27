import os
from pathlib import Path
import subprocess
import tempfile
import unittest


BASE = Path(__file__).resolve().parents[1] / "base/etc"


class PeerSSH(unittest.TestCase):
    def render(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "sshd_config"
            subprocess.run([
                "bash", "-e", str(BASE / "runit_init.d/01_sshd_config.sh"),
            ], env={"PATH": os.defpath, "BASE": "/home", "CCC_SSHD_CONFIG": str(target)}, check=True)
            return target.read_text()

    def test_default_server_hook_preserves_personal_key_paths(self):
        config = self.render()
        self.assertIn("\nAuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2 "
                      "/run/compute-container-keymaster/authorized_keys/%u\n", config)

    def test_system_client_hook(self):
        self.assertEqual((BASE / "ssh/ssh_config.d/20-compute-container-keymaster.conf").read_text().splitlines()[-1],
                         "Include /run/compute-container-keymaster/client.conf")

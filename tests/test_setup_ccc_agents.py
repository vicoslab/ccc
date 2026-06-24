"""Tests for the CCC image ccc-agent-containment setup wrapper."""

import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CCC_DIR = os.path.dirname(HERE)
SETUP_SH = os.path.join(CCC_DIR, "base", "etc", "setup_ccc_agents.sh")


class TestSetupCccAgents(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        self.args_file = os.path.join(self.tmp, "setup-args.txt")
        self._write_executable("branchfs", "#!/bin/sh\nexit 0\n")
        self._write_executable("bwrap", "#!/bin/sh\nexit 0\n")
        self._write_executable(
            "ccc-agent-setup",
            "#!/bin/sh\n"
            "if [ \"${1:-}\" = --help ]; then\n"
            "  echo 'usage: ccc-agent-setup --storage-root --conda-activate-shims'\n"
            "  exit 0\n"
            "fi\n"
            "printf '%s\n' \"$@\" > \"$CCC_AGENT_TEST_ARGS_FILE\"\n"
            "exit 0\n",
        )

    def tearDown(self):
        self._tmp.cleanup()

    def _write_executable(self, name, content):
        path = os.path.join(self.bin, name)
        with open(path, "w") as fh:
            fh.write(content)
        os.chmod(path, 0o755)
        return path

    def run_setup(self, extra_env=None):
        env = {
            "PATH": "%s:/usr/bin:/bin" % self.bin,
            "CCC_AGENT_TEST_ARGS_FILE": self.args_file,
            "CCC_AGENT_CONTAINMENT_INSTALL_DIR": os.path.join(self.tmp, "install"),
            "CCC_AGENT_CONFIG": os.path.join(self.tmp, "config.json"),
            "CCC_AGENT_CONTAINMENT_ENABLE_SHIMS": "1",
            "CCC_AGENT_CONTAINMENT_LINK_DIR": os.path.join(self.tmp, "shims"),
            "USER_NAME": "cccagenttest",
            "CONTAINER_NAME": "domen-cuda10",
        }
        env.update(extra_env or {})
        proc = subprocess.run(
            ["sh", SETUP_SH, "--wire-only"],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return proc

    def setup_args(self):
        with open(self.args_file) as fh:
            return fh.read().splitlines()

    def test_wire_passes_conda_shim_activation_flags_when_enabled(self):
        conda_prefix = os.path.join(self.tmp, "conda-env")
        proc = self.run_setup({
            "CCC_AGENT_CONTAINMENT_CONDA_ACTIVATE_SHIMS": "1",
            "CCC_AGENT_CONTAINMENT_CONDA_PREFIX": conda_prefix,
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)
        args = self.setup_args()
        self.assertIn("--enable-shims", args)
        self.assertIn("--link-dir", args)
        self.assertIn("--conda-activate-shims", args)
        self.assertEqual(args[args.index("--conda-prefix") + 1], conda_prefix)

    def test_wire_omits_conda_flags_by_default(self):
        proc = self.run_setup()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        args = self.setup_args()
        self.assertIn("--enable-shims", args)
        self.assertNotIn("--conda-activate-shims", args)
        self.assertNotIn("--conda-prefix", args)


if __name__ == "__main__":
    unittest.main()

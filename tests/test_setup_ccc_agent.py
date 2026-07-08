"""Tests for the CCC image ccc-agent setup wrapper."""

import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CCC_DIR = os.path.dirname(HERE)
SETUP_SH = os.path.join(CCC_DIR, "base", "etc", "setup_ccc_agent.sh")


class TestSetupCccAgents(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        self.args_file = os.path.join(self.tmp, "setup-args.txt")
        self.pip_args_file = os.path.join(self.tmp, "pip-args.txt")
        self.install_dir = os.path.join(self.tmp, "install")
        self.link_dir = os.path.join(self.tmp, "shims")
        self._write_executable("branchfs", "#!/bin/sh\nexit 0\n")
        self._write_executable("bwrap", "#!/bin/sh\nexit 0\n")
        self._write_executable("git", "#!/bin/sh\nexit 0\n")
        self._write_executable(
            "ccc-agent",
            "#!/bin/sh\n"
            "if [ \"${1:-}\" = setup ] && [ \"${2:-}\" = --help ]; then\n"
            "  echo 'usage: ccc-agent setup --storage-root --conda-activate-shims'\n"
            "  exit 0\n"
            "fi\n"
            "printf '%s\n' \"$@\" > \"$CCC_AGENT_TEST_ARGS_FILE\"\n"
            "exit 0\n",
        )

    def tearDown(self):
        self._tmp.cleanup()

    def _write_executable(self, name, content):
        path = os.path.join(self.bin, name)
        return self._write_executable_at(path, content)

    def _write_executable_at(self, path, content):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(content)
        os.chmod(path, 0o755)
        return path

    def _write_fake_system_python(self):
        return self._write_executable_at(
            os.path.join(self.tmp, "system-python3"),
            "#!/bin/sh\n"
            "printf '%s\\n' \"$*\" >> \"$CCC_AGENT_TEST_PIP_ARGS_FILE\"\n"
            "exit 0\n",
        )

    def base_env(self, extra_env=None):
        env = {
            "PATH": "%s:/usr/bin:/bin" % self.bin,
            "CCC_AGENT_TEST_ARGS_FILE": self.args_file,
            "CCC_AGENT_TEST_PIP_ARGS_FILE": self.pip_args_file,
            "CCC_AGENT_INSTALL_DIR": self.install_dir,
            "CCC_AGENT_CONFIG": os.path.join(self.tmp, "config.json"),
            "CCC_AGENT_ENABLE_SHIMS": "1",
            "CCC_AGENT_LINK_DIR": self.link_dir,
            "USER_NAME": "cccagenttest",
            "CONTAINER_NAME": "domen-cuda10",
        }
        env.update(extra_env or {})
        return env

    def run_setup(self, extra_env=None):
        env = self.base_env(extra_env)
        proc = subprocess.run(
            ["sh", SETUP_SH, "--wire-only"],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return proc

    def run_install(self, extra_env=None):
        env = self.base_env({
            "CCC_AGENT_INSTALL_DEPS": "0",
            "CCC_AGENT_SYSTEM_PYTHON": self._write_fake_system_python(),
            "CCC_AGENT_BRANCHFS_BIN": os.path.join(self.bin, "branchfs"),
        })
        env.update(extra_env or {})
        proc = subprocess.run(
            ["sh", SETUP_SH, "--install-only"],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return proc

    def setup_args(self):
        with open(self.args_file) as fh:
            return fh.read().splitlines()

    def pip_invocations(self):
        with open(self.pip_args_file) as fh:
            return fh.read().splitlines()

    def test_wire_passes_conda_shim_activation_flags_when_enabled(self):
        conda_prefix = os.path.join(self.tmp, "conda-env")
        proc = self.run_setup({
            "CCC_AGENT_CONDA_ACTIVATE_SHIMS": "1",
            "CCC_AGENT_CONDA_PREFIX": conda_prefix,
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

    def test_install_does_not_treat_user_path_ccc_agent_as_system_install(self):
        os.makedirs(self.install_dir, exist_ok=True)
        with open(os.path.join(self.install_dir, ".ccc-agent-ref"), "w") as fh:
            fh.write("master\n")

        proc = self.run_install()

        self.assertEqual(proc.returncode, 0, proc.stderr)
        invocations = self.pip_invocations()
        self.assertTrue(any(" pip install " in " %s " % line
                            for line in invocations), invocations)

    def test_forced_update_reinstalls_same_version_package_without_cache(self):
        proc = self.run_install({"CCC_AGENT_UPDATE": "1"})

        self.assertEqual(proc.returncode, 0, proc.stderr)
        install_lines = [line for line in self.pip_invocations()
                         if " pip install " in " %s " % line]
        self.assertTrue(install_lines, self.pip_invocations())
        install_line = install_lines[-1]
        self.assertIn("--force-reinstall", install_line)
        self.assertIn("--no-cache-dir", install_line)

    def test_install_requests_branchfs_extra_by_default(self):
        proc = self.run_install()

        self.assertEqual(proc.returncode, 0, proc.stderr)
        install_lines = [line for line in self.pip_invocations()
                         if " pip install " in " %s " % line]
        self.assertTrue(install_lines, self.pip_invocations())
        self.assertIn("ccc-agent[branchfs]", install_lines[-1])

    def test_install_can_disable_branchfs_extra_for_operator_binary(self):
        proc = self.run_install({"CCC_AGENT_INSTALL_BRANCHFS_EXTRA": "0"})

        self.assertEqual(proc.returncode, 0, proc.stderr)
        install_lines = [line for line in self.pip_invocations()
                         if " pip install " in " %s " % line]
        self.assertTrue(install_lines, self.pip_invocations())
        self.assertNotIn("[branchfs]", install_lines[-1])

    def test_wire_lets_ccc_agent_setup_resolve_packaged_branchfs_by_default(self):
        proc = self.run_setup()

        self.assertEqual(proc.returncode, 0, proc.stderr)
        args = self.setup_args()
        self.assertNotIn("--branchfs-bin", args)

    def test_wire_passes_explicit_branchfs_override_when_configured(self):
        explicit = os.path.join(self.bin, "branchfs")
        proc = self.run_setup({"CCC_AGENT_BRANCHFS_BIN": explicit})

        self.assertEqual(proc.returncode, 0, proc.stderr)
        args = self.setup_args()
        self.assertEqual(args[args.index("--branchfs-bin") + 1], explicit)

    def test_wire_prefers_system_entrypoint_for_latest_shims(self):
        system_args_file = os.path.join(self.tmp, "system-setup-args.txt")
        self._write_executable_at(
            os.path.join(self.link_dir, "ccc-agent"),
            "#!/bin/sh\n"
            "if [ \"${1:-}\" = setup ] && [ \"${2:-}\" = --help ]; then\n"
            "  echo 'usage: ccc-agent setup --storage-root --conda-activate-shims'\n"
            "  exit 0\n"
            "fi\n"
            "printf '%s\\n' \"$@\" > \"$CCC_AGENT_TEST_SYSTEM_ARGS_FILE\"\n"
            "exit 0\n",
        )

        proc = self.run_setup({"CCC_AGENT_TEST_SYSTEM_ARGS_FILE": system_args_file})

        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(os.path.exists(system_args_file), proc.stderr)
        self.assertFalse(os.path.exists(self.args_file),
                         "PATH user ccc-agent was used instead of system entrypoint")


if __name__ == "__main__":
    unittest.main()

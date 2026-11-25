"""Exercise the real startup scripts and timestamp markers without Docker."""
import os
from pathlib import Path
import pwd
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'base/etc/ccc-install-lock.sh'
STEPS = {
    'user': 'base/etc/runit_init.d/02_user.sh',
    'miniconda': 'base/etc/runit_init.d/03_miniconda.sh',
    'ccc-tools': 'base/etc/runit_init.d/04_ccc_tools.sh',
    'jetbrains-projector': 'jetbrains-projector/etc/runit_init.d/30_jetbrains_projector.sh',
}


class InstallLocks(unittest.TestCase):
    def setUp(self):
        fixture = tempfile.TemporaryDirectory()
        self.addCleanup(fixture.cleanup)
        self.fixture = Path(fixture.name)
        user = pwd.getpwuid(os.getuid()).pw_name
        self.home = self.fixture / user
        self.home.mkdir()
        self.etc = self.fixture / 'etc'
        self.init = self.etc / 'runit_init.d'
        self.init.mkdir(parents=True)
        for source in STEPS.values():
            shutil.copy2(ROOT / source, self.init)
        if HELPER.exists():
            shutil.copy2(HELPER, self.etc)
        self.bin = self.fixture / 'bin'
        self.bin.mkdir()
        # Preserve the exact exec environment, as runit's chpst does. A /bin/sh
        # trampoline can discard exported Bash functions before the real exec.
        chpst = self.bin / 'chpst'
        chpst.write_text('#!/usr/bin/python3\nimport os, sys\n'
                         'assert sys.argv[1:3] == ["-u", os.environ["USER_NAME"]]\n'
                         'os.execvp(sys.argv[3], sys.argv[3:])\n')
        chpst.chmod(0o755)
        self.script(self.bin / 'getent', 'if [ "$1" = passwd ]; then exec /usr/bin/getent "$@"; fi\n')
        self.script(self.bin / 'ln', 'case "$3" in /usr/bin/ccc|/etc/profile.d/conda.sh) exit 0;; esac\nexec /usr/bin/ln "$@"\n')
        conda = self.home / 'conda/bin/conda'
        conda.parent.mkdir(parents=True)
        self.script(conda, 'case "$*" in\n "env list") printf "ccc-tools /test/ccc-tools\\njetbrains-projector /test/projector\\n";;\n "run -n ccc-tools which ccc") printf "/test/ccc\\n";;\n "run -n jetbrains-projector projector config list") printf "config fixture-default\\n";;\n *) exit 2;;\nesac\n')
        self.env = {
            'PATH': f'{self.bin}:/usr/bin:/bin', 'BASE': str(self.fixture),
            'HOME': str(self.home), 'USER_NAME': user, 'USER_ID': str(os.getuid()),
            'HOSTNAME': 'fixture', 'CCC_INSTALL_LOCK_TIMEOUT': '3600',
        }

    @staticmethod
    def script(path, body):
        path.write_text('#!/bin/sh\n' + body)
        path.chmod(0o755)

    def step(self, name):
        return subprocess.run([str(self.init / Path(STEPS[name]).name)], env=self.env,
                              capture_output=True, text=True, timeout=3)

    def run_lock(self, lock, *command, **kwargs):
        return subprocess.run(['/bin/bash', str(HELPER), str(lock), *command],
                              env=self.env, capture_output=True, text=True, timeout=3, **kwargs)

    def lock_path(self, name):
        return self.home / f'{name}.installing'

    def test_each_init_step_recovers_stale_empty_legacy_marker(self):
        for name in STEPS:
            with self.subTest(step=name):
                marker = self.lock_path(name)
                marker.touch()
                os.utime(marker, (1, 1))
                result = self.step(name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(marker.exists())

    def test_fresh_timestamp_overrides_old_mtime_and_waits(self):
        lock = self.lock_path('user')
        for content in (f'{int(time.time())}\n', ''):
            with self.subTest(content=content):
                lock.write_text(content)
                if content:
                    os.utime(lock, (1, 1))
                child = self.start_lock(lock, 'true')
                try:
                    with self.assertRaises(subprocess.TimeoutExpired):
                        child.wait(timeout=0.3)
                    self.assertEqual(lock.read_text(), content)
                    lock.unlink()
                    self.assertEqual(child.wait(timeout=4), 0)
                finally:
                    self.stop_lock(child)

    def start_lock(self, lock, *command):
        return subprocess.Popen(['/bin/bash', str(HELPER), str(lock), *command],
                                env=self.env, start_new_session=True)

    def test_simultaneous_startups_do_not_both_claim_a_missing_marker(self):
        lock = self.lock_path('user')
        release = self.fixture / 'release'
        entries = [self.fixture / f'entered-{i}' for i in range(2)]
        children = [self.start_lock(lock, '/bin/bash', '-c',
                                    'touch "$1"; until [[ -e $2 ]]; do sleep .02; done',
                                    'installer', str(entry), str(release))
                    for entry in entries]
        try:
            deadline = time.monotonic() + 3
            while not any(entry.exists() for entry in entries) and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertEqual(sum(entry.exists() for entry in entries), 1)
            # The first stays inside while the second contends for the marker.
            time.sleep(0.3)
            self.assertEqual(sum(entry.exists() for entry in entries), 1)
            release.touch()
            for child in children:
                self.assertEqual(child.wait(timeout=4), 0)
            self.assertTrue(all(entry.exists() for entry in entries))
            self.assertFalse(lock.exists())
        finally:
            for child in children:
                self.stop_lock(child)

    @staticmethod
    def stop_lock(child):
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=3)

    @staticmethod
    def wait_for(path, child):
        deadline = time.monotonic() + 3
        while not path.exists() and child.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)

    def test_new_account_creation_does_not_populate_a_shared_home(self):
        shutil.rmtree(self.home)
        self.script(self.bin / 'getent', 'exit 2\n')
        self.script(self.bin / 'adduser',
                    'for arg; do [ "$arg" != --no-create-home ] || exit 0; done\n'
                    'echo "adduser would copy skeleton files outside the lock" >&2\nexit 42\n')
        self.script(self.bin / 'cp',
                    'read -r timestamp owner < "$HOME/user.installing" || exit 43\n'
                    '[ "$timestamp" -gt 0 ] || exit 44\n'
                    'touch "$HOME/skel-copied"\n')
        result = self.step('user')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / 'skel-copied').is_file())

    def test_ccc_tools_failed_env_query_attempts_optional_install(self):
        conda = self.home / 'conda/bin/conda'
        self.script(conda, 'case "$1" in\n'
                    ' env) exit 2;;\n'
                    ' create) touch "$HOME/attempted"; exit 3;;\n'
                    ' *) exit 42;;\nesac\n')
        result = self.step('ccc-tools')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('continuing anyway', result.stderr)
        self.assertTrue((self.home / 'attempted').is_file())

    def test_killed_installer_leaves_a_marker_that_expires(self):
        lock = self.lock_path('miniconda')
        ready = self.fixture / 'ready'
        clock = self.fixture / 'clock'
        clock.write_text('100000\n')
        self.script(self.bin / 'date', f'cat "{clock}"\n')
        holder = self.start_lock(lock, '/bin/bash', '-c',
                                 'touch "$1"; exec sleep 60', 'holder', str(ready))
        try:
            self.wait_for(ready, holder)
            self.assertTrue(ready.exists(), 'holder never entered the lock')
            self.stop_lock(holder)
            self.assertEqual(holder.returncode, -signal.SIGKILL)
            self.assertEqual(lock.read_text().split()[0], '100000')
            clock.write_text('103600\n')
            result = self.run_lock(lock, '/bin/bash', '-c', 'cat "$1"', 'inspect', str(lock))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.split()[0], '103600')
            self.assertFalse(lock.exists())
        finally:
            self.stop_lock(holder)

    def test_finishing_old_installer_does_not_remove_replacement(self):
        lock = self.lock_path('miniconda')
        ready, release = self.fixture / 'ready', self.fixture / 'release'
        holder = self.start_lock(lock, '/bin/bash', '-c',
                                 'touch "$1"; until [[ -e $2 ]]; do sleep .02; done',
                                 'holder', str(ready), str(release))
        try:
            self.wait_for(ready, holder)
            self.assertTrue(ready.exists())
            lock.unlink()
            new_record = f'{int(time.time())} replacement\n'
            lock.write_text(new_record)
            release.touch()
            self.assertEqual(holder.wait(timeout=3), 0)
            self.assertEqual(lock.read_text(), new_record)
        finally:
            self.stop_lock(holder)

    def test_two_stale_recoverers_cannot_unlink_the_replacement(self):
        lock = self.lock_path('miniconda')
        lock.write_text('1\n')
        paused, unblock = self.fixture / 'paused', self.fixture / 'unblock'
        entered_a, entered_b, finish_b = [self.fixture / name for name in ('a', 'b', 'finish-b')]
        self.script(self.bin / 'rm',
                    'if [ "$PAUSE_REMOVAL" = 1 ] && [ "$3" = "$HOME/miniconda.installing" ]; then\n'
                    f'  touch "{paused}"\n'
                    f'  until [ -e "{unblock}" ]; do sleep .02; done\n'
                    'fi\nexec /usr/bin/rm "$@"\n')
        self.env['PAUSE_REMOVAL'] = '1'
        first = self.start_lock(lock, 'touch', str(entered_a))
        self.env.pop('PAUSE_REMOVAL')
        second = None
        try:
            self.wait_for(paused, first)
            self.assertTrue(paused.exists(), 'first startup did not reach stale removal')
            second = self.start_lock(lock, '/bin/bash', '-c',
                                     'touch "$1"; until [[ -e $2 ]]; do sleep .02; done',
                                     'installer', str(entered_b), str(finish_b))
            self.wait_for(entered_b, second)
            self.assertFalse(entered_b.exists(), 'another startup bypassed in-progress stale removal')
            unblock.touch()
            finish_b.touch()
            self.assertEqual(first.wait(timeout=5), 0)
            self.assertEqual(second.wait(timeout=5), 0)
            self.assertTrue(entered_a.exists() and entered_b.exists())
        finally:
            self.stop_lock(first)
            if second is not None:
                self.stop_lock(second)

    def test_killed_stale_remover_does_not_block_future_recovery(self):
        lock = self.lock_path('miniconda')
        lock.write_text('1 4c633e61-66a0-4f5e-8d75-c36a53148235\n')
        paused = self.fixture / 'paused'
        self.script(self.bin / 'rm',
                    'if [ "$PAUSE_REMOVAL" = 1 ] && [ "$3" = "$HOME/miniconda.installing" ]; then\n'
                    f'  touch "{paused}"\n'
                    '  exec sleep 60\n'
                    'fi\nexec /usr/bin/rm "$@"\n')
        self.env['PAUSE_REMOVAL'] = '1'
        remover = self.start_lock(lock, 'true')
        self.env.pop('PAUSE_REMOVAL')
        try:
            self.wait_for(paused, remover)
            self.assertTrue(paused.exists())
        finally:
            self.stop_lock(remover)
        self.assertTrue(lock.exists())
        tickets = list(self.home.glob('*.installing.remove-*/0'))
        self.assertEqual(len(tickets), 1)
        os.utime(tickets[0], (1, 1))
        result = self.run_lock(lock, 'true')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(lock.exists())
        self.assertEqual(list(self.home.glob('*.installing.remove-*')), [])

    def test_installer_error_releases_lock_and_preserves_exit_status(self):
        lock = self.lock_path('miniconda')
        result = self.run_lock(lock, '/bin/bash', '-c', 'exit 42')
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertFalse(lock.exists())
        self.assertEqual(self.run_lock(lock, 'true').returncode, 0)

    def test_default_expiry_is_one_hour_and_bad_override_fails(self):
        lock = self.lock_path('user')
        self.env.pop('CCC_INSTALL_LOCK_TIMEOUT')
        self.script(self.bin / 'date', 'printf "%s\\n" 100000\n')
        lock.write_text('96401\n')
        child = self.start_lock(lock, 'true')
        try:
            with self.assertRaises(subprocess.TimeoutExpired):
                child.wait(timeout=0.3)
        finally:
            self.stop_lock(child)
        self.assertEqual(lock.read_text(), '96401\n')
        lock.write_text('96400\n')
        result = self.run_lock(lock, 'true')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(lock.exists())
        self.env['CCC_INSTALL_LOCK_TIMEOUT'] = '0'
        result = self.run_lock(lock, 'true')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('CCC_INSTALL_LOCK_TIMEOUT', result.stderr)


if __name__ == '__main__':
    unittest.main()

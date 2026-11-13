#!/usr/bin/env python3
"""theoui stops every instance of a test profile, not only the one in its pid file.

The fault suite's F14 left a second copy of its profile running: the pid file only holds the newest launch, so an
older copy that outlived its stop was never found again. These stand-ins are plain Python sleepers carrying the same
`--profile test-<name>` arguments a Theo launch has; no Theo is started.

  python3 Tools/tests/test_theoui_instances.py
"""
import importlib, os, pathlib, shutil, signal, subprocess, sys, time, unittest, uuid

TOOLS = pathlib.Path(__file__).resolve().parent.parent


def load(profile):
    os.environ["THEOUI_PROFILE"] = profile
    sys.path.insert(0, str(TOOLS))
    try:
        import theoui
        return importlib.reload(theoui)
    finally:
        sys.path.remove(str(TOOLS))


def sleeper(profile_arg, ignore_term=False, equals=False):
    code = "import signal, time\n" + ("signal.signal(signal.SIGTERM, signal.SIG_IGN)\n" if ignore_term else "") + "time.sleep(120)"
    args = [sys.executable, "-c", code] + ([f"--profile={profile_arg}"] if equals else ["--profile", profile_arg])
    proc = subprocess.Popen(args, start_new_session=True)
    time.sleep(0.3)
    return proc


class TheoUIInstances(unittest.TestCase):
    def setUp(self):
        self.name = "unit-" + uuid.uuid4().hex[:8]
        self.ui = load(self.name)
        self.procs = []

    def tearDown(self):
        for proc in self.procs:
            if proc.poll() is None:
                proc.kill()
            proc.wait()
        shutil.rmtree(self.ui.ROOT, ignore_errors=True)

    def spawn(self, *args, **kwargs):
        proc = sleeper(*args, **kwargs)
        self.procs.append(proc)
        return proc

    def test_finds_every_copy_of_this_profile_and_nothing_else(self):
        first = self.spawn(self.ui.PROFILE_ARG)
        second = self.spawn(self.ui.PROFILE_ARG, equals=True)
        other = self.spawn(self.ui.PROFILE_ARG + "-air")   # another tester's profile, a prefix match
        found = self.ui.profile_pids()
        self.assertEqual(sorted(found), sorted([first.pid, second.pid]))
        self.assertNotIn(other.pid, found)

    def test_stop_ends_the_copy_the_pid_file_forgot(self):
        older = self.spawn(self.ui.PROFILE_ARG)
        newer = self.spawn(self.ui.PROFILE_ARG)
        other = self.spawn(self.ui.PROFILE_ARG + "-b")
        self.ui.ROOT.mkdir(parents=True, exist_ok=True)
        self.ui.PIDFILE.write_text(str(newer.pid))   # what F14 left: only the newest is tracked
        self.assertEqual(self.ui.stop(), [])
        for proc in (older, newer):
            proc.wait(timeout=5)
        self.assertEqual(self.ui.profile_pids(), [])
        self.assertFalse(self.ui.PIDFILE.exists())
        self.assertIsNone(other.poll(), "another profile's instance must be left alone")

    def test_a_stale_pid_file_never_stops_another_program(self):
        unrelated = self.spawn("not-a-theo-profile")   # took over the id a stopped instance had
        self.ui.ROOT.mkdir(parents=True, exist_ok=True)
        self.ui.PIDFILE.write_text(str(unrelated.pid))
        self.assertEqual(self.ui.stop(), [])
        self.assertIsNone(unrelated.poll(), "a process without this profile must be left alone")

    def test_start_doesnt_take_a_reused_pid_for_a_running_theo(self):
        unrelated = self.spawn("not-a-theo-profile")
        self.ui.ROOT.mkdir(parents=True, exist_ok=True)
        self.ui.PIDFILE.write_text(str(unrelated.pid))
        self.assertIsNone(self.ui.tracked_instance(), "start would have returned this id instead of launching Theo")
        mine = self.spawn(self.ui.PROFILE_ARG)
        self.ui.PIDFILE.write_text(str(mine.pid))
        self.assertEqual(self.ui.tracked_instance(), mine.pid)

    def test_a_copy_that_ignores_sigterm_is_killed(self):
        stubborn = self.spawn(self.ui.PROFILE_ARG, ignore_term=True)
        self.assertEqual(self.ui.stop_pids([stubborn.pid], wait=1), [])
        self.assertEqual(stubborn.wait(timeout=5), -signal.SIGKILL)


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""The limits every download sweep keeps (Tools/signs/studio/sweep_guard.py): free space, raw videos at a time, a
required budget, the plan printed first, and nothing read twice."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "studio"))
import sweep_guard  # noqa: E402


def test_a_batch_never_starts_under_60_gb_free():
    sweep_guard.check_free_space(60.0)
    with pytest.raises(sweep_guard.StopJob, match="60 GB"):
        sweep_guard.check_free_space(59.9)


def test_a_batch_never_starts_while_raw_videos_are_left():
    sweep_guard.check_no_raw_videos_left(0.0)
    with pytest.raises(sweep_guard.StopJob, match="--finish-batch"):
        sweep_guard.check_no_raw_videos_left(5.8)


def test_batches_stay_under_the_raw_video_cap():
    sizes_mb = [700.0] * 40  # 28 GB in all
    batches = sweep_guard.cut_into_batches(list(range(40)), sizes_mb, cap_gb=12.0)
    assert sum(len(batch) for batch in batches) == 40
    assert [item for batch in batches for item in batch] == list(range(40))  # in order, nothing lost
    assert all(sum(sizes_mb[item] for item in batch) <= 12000 for batch in batches)
    # estimated sizes count 1.3 times over, so their batches are smaller
    estimated = sweep_guard.cut_into_batches(list(range(40)), sizes_mb, cap_gb=12.0, exact_sizes=False)
    assert all(sum(sizes_mb[item] for item in batch) * sweep_guard.ESTIMATE_SAFETY <= 12000 for batch in estimated)
    assert len(estimated) > len(batches)


def test_an_item_bigger_than_the_cap_is_a_batch_of_its_own_and_counts_cap_too():
    assert sweep_guard.cut_into_batches(["a", "b", "c"], [20000.0, 1.0, 1.0], cap_gb=12.0) == [["a"], ["b", "c"]]
    assert sweep_guard.cut_into_batches(list(range(5)), [1.0] * 5, most_items=2) == [[0, 1], [2, 3], [4]]


def test_the_budget_stops_before_a_batch_would_pass_it():
    budget = sweep_guard.DownloadBudget(40.0)
    assert budget.allows(12.0)
    budget.spend(30.0)
    assert budget.allows(10.0) and not budget.allows(10.5)
    with pytest.raises(ValueError):
        sweep_guard.DownloadBudget(0)


def test_the_ledger_keeps_what_was_read_across_runs(tmp_path):
    ledger = sweep_guard.ReadLedger(tmp_path / "state" / "read.tsv")
    assert "train/hello/a.mp4" not in ledger
    ledger.add_all(["train/hello/a.mp4", "train/hello/b.mp4", "train/hello/a.mp4"])
    again = sweep_guard.ReadLedger(tmp_path / "state" / "read.tsv")
    assert "train/hello/a.mp4" in again and "train/hello/b.mp4" in again
    assert (tmp_path / "state" / "read.tsv").read_text().count("a.mp4") == 1


def test_the_plan_line_says_the_total_and_the_limits():
    line = sweep_guard.plan_line("popsign", 1, 3200, 26.4, 40, exact=False)
    assert "26.4 GB to download" in line and "budget 40 GB" in line and "12 GB of raw videos" in line and "60 GB free" in line


@pytest.mark.parametrize("script", ["popsign_sweeps.py", "fsboard_sweeps.py"])
def test_the_sweep_scripts_require_sweeps_and_a_budget(script):
    import subprocess
    studio = Path(__file__).resolve().parent.parent / "studio"
    source = (studio / script).read_text()
    assert '"--max-sweeps"' in source and '"--max-download-gb"' in source
    assert "default=5" not in source  # no open-ended default
    assert "check_free_space" in source and "check_no_raw_videos_left" in source and "ReadLedger" in source
    # Run with no arguments it refuses before touching anything.
    result = subprocess.run([sys.executable, str(studio / script)], capture_output=True, text=True,
                            env={"HOME": "/nonexistent-home-for-the-test", "PATH": "/usr/bin:/bin"})
    assert result.returncode != 0 and "required" in result.stderr

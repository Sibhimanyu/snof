"""Report retention (reports.prune_reports). No network, no Firebase.

Run from dashboard/functions:  python3 tests/test_prune.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import reports  # noqa: E402


class Ref:
    def __init__(self, db, path): self.db, self.path = db, path
    def get(self, shallow=False):
        node = self.db.data.get(self.path)
        return {k: True for k in node} if shallow and isinstance(node, dict) else node
    def update(self, patch):
        node = self.db.data.setdefault(self.path, {})
        for k, v in patch.items():
            if v is None: node.pop(k, None)
            else: node[k] = v


class DB:
    def __init__(self, data): self.data = data
    def reference(self, path): return Ref(self, path)


def test_keeps_the_newest():
    keys = [f"-P{n:04d}" for n in range(90)]                 # push ids sort by time
    db = DB({"farms/snof/irrigation_reports": {k: {"type": "controller"} for k in keys}})
    assert reports.prune_reports(db, "farms/snof", keep=60) == 30
    left = sorted(db.data["farms/snof/irrigation_reports"])
    assert left == keys[30:], "the oldest 30 go, the newest 60 stay"


def test_small_or_missing_is_left_alone():
    db = DB({"farms/snof/irrigation_reports": {"-A": {}, "-B": {}}})
    assert reports.prune_reports(db, "farms/snof", keep=60) == 0
    assert reports.prune_reports(DB({}), "farms/snof") == 0




def test_run_log_cache_is_not_capped_at_32():
    rows = [{"at": f"2026-09-2{3 + i // 30} {i % 24:02d}:{(i * 7) % 60:02d}:00", "event": "Program · X",
             "detail": "1h, finished · 12 Coco 1", "source": "timer"} for i in range(60)]
    patch = {"timerLog": rows, "valves": list(range(40))}
    out = {k: ([reports.V.scrub(r) for r in v] if k in reports.LONG_CACHE and isinstance(v, list) else reports.V.scrub(v))
           for k, v in patch.items()}
    assert len(out["timerLog"]) == 60, "two busy days fit"
    assert len(out["valves"]) == 32, "everything else keeps the old cap"
    assert reports.CACHE_RUNS >= 120


if __name__ == "__main__":  # noqa
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn(); print(f"ok  {name}")

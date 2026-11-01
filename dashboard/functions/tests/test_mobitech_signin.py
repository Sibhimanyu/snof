"""Web sign-in to Mobitech (mobitech_signin.py). No network, no Firebase.

Run from dashboard/functions:  python3 tests/test_mobitech_signin.py
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

import dcon  # noqa: E402
import mobitech_signin as M  # noqa: E402


class Ref:
    def __init__(self, tree, path): self.t, self.p = tree, path
    def get(self): return self.t.get(self.p)
    def set(self, v): self.t[self.p] = v
    def update(self, v): self.t[self.p] = {**(self.t.get(self.p) or {}), **v}


class Store:
    def __init__(self, **tree): self.tree = dict(tree)
    def reference(self, path): return Ref(self.tree, path)


class Src:
    """A stand-in for dcon.Dcon with canned, already-reduced answers."""
    def __init__(self, otp=None, login=None, prove=None):
        self._o, self._l, self._p, self.calls = otp, login, prove, []
    def _go(self, name, val, *a):
        self.calls.append((name, a))
        if isinstance(val, Exception): raise val
        return val
    def otp(self, m): return self._go("otp", self._o, m)
    def login(self, m, c, t): return self._go("login", self._l, m, c, t)
    def prove(self, t): return self._go("prove", self._p, t)


TOKEN = "T" * 22 + ":APA91b" + "u" * 134 + "@ios"
GOOD_LOGIN = {"state": "ok", "idOk": True, "name": "Sibhi", "uname": "sibhi"}


def test_the_device_token_has_the_apps_shape_and_is_random():
    t = M.device_token()
    assert M.TOKEN_SHAPE.match(t) and t.endswith("@ios") and len(t) == 22 + 7 + 134 + 4
    assert t[22:29] == ":APA91b"
    assert M.device_token() != t
    # and it passes the relay's own shape rule
    import re
    assert re.match(r"^[A-Za-z0-9_:\-]{36,400}@ios$", t)


def test_input_is_validated_like_the_other_sign_in():
    assert M.mobile10("98765 43210") == "9876543210"
    assert M.mobile10("+91 98765 43210") == "9876543210"
    for bad in ("12345", "5876543210", "", None, "98765432101"):
        assert M.mobile10(bad) is None, bad
    assert M.code_digits(" 123 456 ") == "123456"
    for bad in ("12", "123456789", "abc", None):
        assert M.code_digits(bad) is None, bad


def test_send_code_is_rate_limited_to_one_per_30_seconds():
    store, src = Store(), Src(otp={"message": "Success"})
    assert M.send_code(store, src, "9876543210", now_ms=1_000_000) == ({"ok": True}, 200)
    out, status = M.send_code(store, src, "9876543210", now_ms=1_010_000)
    assert status == 429 and not out["ok"] and len(src.calls) == 1
    assert M.send_code(store, src, "9876543210", now_ms=1_031_000)[1] == 200


def test_send_code_says_why_it_failed():
    out, status = M.send_code(Store(), Src(otp={"message": "Mobile number not registered"}), "9876543210", 1e9)
    assert status == 502 and "not registered" in out["error"]
    err = dcon.DconError("DCON otp: the farm's bridge did not answer — is the NUC online?")
    out, _ = M.send_code(Store(), Src(otp=err), "9876543210", 1e9)
    assert out["error"] == M.NO_BRIDGE


def test_verify_keeps_a_session_only_after_login_and_proof():
    store = Store(**{"farms/snof/mobitech_status": {"at": 1, "lastOk": 5, "lastRejected": 6}})
    src = Src(login=GOOD_LOGIN, prove={"serves": True})
    out, status = M.verify(store, "farms/snof", src, "9876543210", "123456", "uid1", mint=lambda: TOKEN)
    assert (out, status) == ({"ok": True, "name": "Sibhi"}, 200)
    assert TOKEN not in json.dumps(out)
    assert src.calls == [("login", ("9876543210", "123456", TOKEN)), ("prove", (TOKEN,))]
    assert store.tree["private/mobitech"] == {"token": TOKEN, "at": M.SERVER_TIMESTAMP, "uid": "uid1"}
    # replaced whole: lastOk / lastRejected from the old session are gone
    assert store.tree["farms/snof/mobitech_status"] == {
        "at": M.SERVER_TIMESTAMP, "uid": "uid1", "name": "Sibhi", "user": "sibhi", "mobileLast4": "3210"}


def test_verify_refuses_and_stores_nothing_when_anything_fails():
    cases = {
        "wrong code": Src(login={"state": "failed", "idOk": False, "message": "Invalid OTP"}),
        "other id": Src(login={**GOOD_LOGIN, "idOk": False}),
        "not served": Src(login=GOOD_LOGIN, prove={"serves": False}),
        "no bridge": Src(login=dcon.DconError("DCON login: the farm's bridge did not answer — x")),
        "garbage": Src(login=None),
    }
    for why, src in cases.items():
        store = Store()
        out, status = M.verify(store, "farms/snof", src, "9876543210", "123456", "u", mint=lambda: TOKEN)
        assert status == 502 and out["ok"] is False and store.tree == {}, why
        assert TOKEN not in json.dumps(out), why
    out, _ = M.verify(Store(), "farms/snof", cases["wrong code"], "9876543210", "1234", "u")
    assert "Invalid OTP" in out["error"]


def test_the_direct_transport_spells_sign_in_like_the_relay():
    assert dcon.signin_request("otp", {"mobile": "9876543210"}) == ("/v1/otp/", '{"mobile":"919876543210"}')
    path, body = dcon.signin_request("login", {"mobile": "9876543210", "code": "123456", "token": "a:b@ios"})
    assert path == "/v1/http/?" and body.endswith("&token=a%3Ab%40ios&product=DCON&app_id=com.mobitech.drip")
    assert dcon.reduce_signin("prove", 200, '{"M":{"users":{}}}') == {"serves": True}
    assert dcon.reduce_signin("login", 200, '{"state":"ok","id":"x","mobile":"9876543210"}', "x") == \
        {"state": "ok", "idOk": True, "name": "", "uname": ""}


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in tests:
        fn()
        print(f"  PASS  {fn.__name__}")
    print(f"\n{len(tests)} tests passed")

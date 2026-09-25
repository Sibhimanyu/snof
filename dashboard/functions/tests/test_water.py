"""The water chain (water.py). No network, no Firebase.

Run from dashboard/functions:  python3 tests/test_water.py

Fixtures copy the *shapes* of the 2026-09-24 captures (docs/livesky-app.md,
docs/niagara-app.md) with invented values: no real id, IMEI, SIM, phone or
host appears here. What matters most is what must NOT come through: the
modem's IP, the account email, the SIM and IMEI, the phone in
"OPERATED BY:", and any id that works as a Niagara credential.
"""
import base64
import copy
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

import water as W  # noqa: E402

PHONE = "9876543210"
IMEI = "861234567890123"

LIVE_ON = {
    "id": 7, "time": "2026-09-24 21:59:18", "updated_by_app": 0, "connection_status": "connected",
    "clientip_port": "('::ffff:10.1.2.3', 35460)", "imei": IMEI, "motor": "MOTOR:01", "phase": 3,
    "l1_volt": 475, "l2_volt": 450, "l3_volt": 447, "motor_status": "MOTORON",
    "l1_amps": 10.2, "l2_amps": 10.2, "l3_amps": None, "runtime": "RUNT:003:16:04",
    "dueto_low_volt": "DLV:0", "dueto_high_volt": "DHV:0", "dueto_different_volt": "DDV:0",
    "dueto_amps_problem": "DAP:0", "dueto_dry_load": "DDL:0", "dueto_overload": "DOL:0",
    "mode": "MOBILEMODE", "auto_status_mobilemode": "GAUTOON", "1p_status_mobilemode": "G1PON",
    "auto_status_manualmode": "MAUTOON", "1p_status_manualmode": "M1POFF",
    "stop_timer": "STOPT:001:33:10", "signal_strength": 25, "mobile_operator_name": "X",
    "modem_model": "MT:SIM7600", "mobile_network_type": "NT:4", "timen": "24/09/2026 09:59:18 PM",
}

ZONED_OFF = {
    "userDeviceId": 11, "userId": 22, "status": "0", "Power": "1", "msgcode": "020",
    "ctrlLatestMsg": f"DATE=24/09/2026  TIME=18:43:01 OPERATED BY:{PHONE} FLO:0 M TIM=00:59:42-162/080   By:",
    "liveMessage": "0,1,$L,MOB MOTOR OFFIII,VRB:407 AMP:00.0       ,234,236,236,407,409,407,00.0,00.0,00.0,"
                   "Timer Mode 1,program1,004,V4:V0:V0:V0,01:05:00,00:14:00,0.0,0.0,0.0,0.00F-00,"
                   f"10:20:30:40:50:60,0.0:0.0,0,16:26:40,19:36:09,0,0,0,0,{IMEI},49.9,0,",
    "simNumber": PHONE, "deviceName": "Well motor", "deviceId": IMEI, "model_Id": 5,
    "livesyncDate": "24/9/2026", "livesyncTime": "22:4:4", "msgDesc": "MOTOR OFF III PHASE",
    "motorStatus": "3 PHASE", "programNo": "NA", "zoneNo": "No Active Zone",
    "ZoneRunTime": "NA", "zoneRemainingTime": "NA", "menuId": 5, "referenceId": 6,
}

ZONED_ZONE3 = dict(
    ZONED_OFF, status="1", msgcode="044", msgDesc=" ",
    ctrlLatestMsg="P1 ZONE=004 CLOSE ZONE=003 OPEN FR=0.0 L TIM=00:51:10 RTIM=01:05:00 Pin=0.00,Pout=21.90 "
                  "VRB=404;C1:08.6,C2:00.0,C3:08.4, DATE=24/09/2026  TIME=22:11:57 FLO:0 M TIM=00:01:44-167/080   By:",
    liveMessage="1,1,$L,  MOTOR ON III  ,VRB:404 AMP:08.4      ,231,232,235,401,405,404,08.6,116.3,08.4,"
                "Timer Mode 1,program1,003,V3:V0:V0:V0,01:05:00,01:04:00,0.0,21.9,0.0,0.00F-00,"
                f"10:20:30:40:50:60,0.0:0.0,0,16:28:28,19:36:09,0,0,0,0,{IMEI},49.9,0,",
    livesyncTime="22:12:1", programNo="P1", zoneNo="ZONE 003", ZoneRunTime="00:00:32",
    zoneRemainingTime="01:04:28")

SKIPPED = dict(ZONED_ZONE3, msgcode="114", msgDesc="ZONE SKIPPED BECAUSE OF NO FEEDBACK",
               programNo="No Active Program", zoneNo="No Active Zone",
               ctrlLatestMsg="ZONE=004 SKIPPED BECAUSE OF NO FEEDBACK    DATE=24/09/2026  TIME=22:10:56 FLO:0 By:")

SEVEN_HP_ON = {
    "userDeviceId": 12, "userId": 22, "status": "1", "Power": "1", "msgcode": "001",
    "ctrlLatestMsg": f"DATE=24/09/2026  TIME=22:11:00 OPERATED BY:{PHONE} FLO:0 M TIM=00:00:01-034/100",
    "liveMessage": "", "simNumber": PHONE, "deviceName": "Wellmotor75HP", "deviceId": IMEI,
    "model_Id": 4, "livesyncDate": "", "livesyncTime": "", "msgDesc": "MOTOR ON III PHASE",
    "motorStatus": "3 PHASE", "programNo": "No Active Program", "zoneNo": "No Active Zone",
}


def no_secrets(node, label):
    text = json.dumps(node)
    for bad in (PHONE, IMEI, "10.1.2.3", "OPERATED", '"11"', '"12"', '"22"'):
        assert bad not in text, f"{label}: {bad!r} leaked into {text}"
    for key in ("userDeviceId", "userId", "deviceId", "simNumber", "imei", "clientip_port", "menuId"):
        assert key not in text, f"{label}: key {key} leaked"


def test_livesky_running():
    r = W.parse_livesky_motor(LIVE_ON, "River Motor")
    assert r["running"] is True and r["pending"] is False and r["connected"] is True
    assert r["volts"] == [475, 450, 447] and r["amps"] == [10.2, 10.2]
    assert r["runMinutes"] == 196 and r["stopMinutes"] == 93
    assert r["reportedAt"] == "2026-09-24T21:59:18+05:30"
    assert r["autoStart"] is True and r["power"] is True and r["trips"] == []
    no_secrets(r, "livesky")


def test_livesky_pending_and_trips():
    row = dict(LIVE_ON, motor_status="MOTOROFF-inprogress", dueto_dry_load="DDL:1")
    r = W.parse_livesky_motor(row)
    assert r["running"] is False and r["pending"] is True
    assert r["trips"] == ["dry run"]
    # An auto-start change on its way reads as the value asked for, marked pending.
    r = W.parse_livesky_motor(dict(LIVE_ON, auto_status_mobilemode="GAUTOON-inprogress"))
    assert r["autoStart"] is True and r["pending"] is True
    r = W.parse_livesky_motor(dict(LIVE_ON, auto_status_mobilemode="GAUTOOFF"))
    assert r["autoStart"] is False
    # No volts, no claim of power.
    r = W.parse_livesky_motor(dict(LIVE_ON, l1_volt=None, l2_volt=None, l3_volt=None))
    assert r["power"] is False and r["volts"] == []
    assert W.parse_livesky_motor("junk") == {}


def test_niagara_zoned_off_and_running():
    key, off = W.parse_niagara_controller(ZONED_OFF, "GROUP ONE")
    assert key == "well-motor" and off["role"] == "drip"
    assert off["running"] is False and off["requested"] is False
    assert off["liveAt"] == "2026-09-24T22:04:04+05:30"
    assert off["reportedAt"] == "2026-09-24T18:43:01+05:30"
    assert "program" not in off
    no_secrets(off, "zoned off")

    _, on = W.parse_niagara_controller(ZONED_ZONE3, "GROUP ONE")
    # msgcode 044 is a zone event; the live packet says the motor runs.
    assert on["running"] is True and on["eventCode"] == "044" and on["event"] == "Zone changed"
    assert on["program"] == "P1" and on["zone"] == 3
    assert on["zoneRun"] == "00:00:32" and on["zoneLeft"] == "01:04:28"
    # Just past a zone's end the controller prints minus 4 s as 23:59:56.
    _, wrapped = W.parse_niagara_controller(dict(ZONED_ZONE3, zoneRemainingTime="23:59:56"), "GROUP ONE")
    assert "zoneLeft" not in wrapped and wrapped["zone"] == 3
    assert on["volts"] == [231, 232, 235]
    # Position 12 (116.3) is not a current on this controller.
    assert on["amps"] == [8.6, 8.4]
    assert on["pressureOut"] == 21.9
    no_secrets(on, "zoned on")


def test_niagara_skipped_zone():
    _, s = W.parse_niagara_controller(SKIPPED, "GROUP ONE")
    assert s["skippedZone"] == 4 and s["eventCode"] == "114" and "program" not in s
    assert s["running"] is True
    no_secrets(s, "skipped")


def test_niagara_seven_hp_from_msgcode():
    key, m = W.parse_niagara_controller(SEVEN_HP_ON, "Water 7.5hp")
    assert key == "wellmotor75hp" and m["role"] == "main-farm"
    assert m["running"] is True and m["requested"] is True
    assert m["reportedAt"] == "2026-09-24T22:11:00+05:30"
    assert "liveAt" not in m and "volts" not in m
    _, off = W.parse_niagara_controller(dict(SEVEN_HP_ON, msgcode="020", msgDesc="MOTOR OFF III PHASE"), "Water 7.5hp")
    assert off["running"] is False
    # Asked for on, still reporting off: that difference is "on its way".
    _, asked = W.parse_niagara_controller(dict(SEVEN_HP_ON, msgcode="020", msgDesc="MOTOR OFF III PHASE"), "x")
    assert asked["requested"] is True and asked["running"] is False and "role" not in asked
    # An unknown code with no motor words: unknown, never a guess.
    _, unk = W.parse_niagara_controller(dict(SEVEN_HP_ON, msgcode="077", msgDesc="SOMETHING"), "x")
    assert "running" not in unk
    no_secrets(m, "7.5hp")
    assert W.parse_niagara_controller({"deviceName": ""}) is None


def test_scrub_catches_digits_in_text():
    _, m = W.parse_niagara_controller(dict(SEVEN_HP_ON, msgDesc=f"CALL {PHONE} NOW", msgcode="077"), "x")
    assert PHONE not in json.dumps(m)


def test_jwt_expiry_and_mobile():
    claims = base64.urlsafe_b64encode(json.dumps({"exp": 1790000000, "iat": 1789913600}).encode()).rstrip(b"=").decode()
    assert W.jwt_expiry(f"xx.{claims}.sig") == 1790000000
    assert W.jwt_expiry("not-a-jwt") is None
    assert W.mobile10("+91 98765 43210") == PHONE and W.mobile10("12345") is None


# ---- pull() against a fake database and fake vendors ----

class Ref:
    def __init__(self, db, path):
        self.db, self.path = db, path.strip("/")

    def _walk(self, create=False):
        node = self.db.data
        parts = [p for p in self.path.split("/") if p]
        for p in parts[:-1]:
            if p not in node:
                if not create:
                    return None, parts[-1]
                node[p] = {}
            node = node[p]
        return node, parts[-1]

    def get(self):
        node = self.db.data
        for p in [p for p in self.path.split("/") if p]:
            if not isinstance(node, dict) or p not in node:
                return None
            node = node[p]
        return copy.deepcopy(node)

    def set(self, value):
        parent, leaf = self._walk(create=True)
        parent[leaf] = copy.deepcopy(value)

    def update(self, patch):
        self.db.updates.append((self.path, patch))
        for k, v in patch.items():
            Ref(self.db, f"{self.path}/{k}").set(v)

    def delete(self):
        parent, leaf = self._walk()
        if parent is not None:
            parent.pop(leaf, None)

    def transaction(self, fn):
        self.set(fn(self.get()))


class DB:
    def __init__(self, data=None):
        self.data, self.updates = data or {}, []

    def reference(self, path):
        return Ref(self, path)


class FakeNiagara:
    def __init__(self, fail=False):
        self.fail, self.calls = fail, 0

    def groups(self):
        self.calls += 1
        if self.fail:
            raise W.VendorError("Niagara: HTTP 502")
        return [{"userGroupId": 1, "groupName": "GROUP ONE"}, {"userGroupId": 2, "groupName": "Water 7.5hp"},
                {"userGroupId": 3, "groupName": "Irrigation 5HP"}]

    def controllers(self, gid):
        return {1: [ZONED_ZONE3], 2: [SEVEN_HP_ON], 3: []}[gid]


class FakeLivesky:
    calls = []

    def __init__(self, base, token=""):
        self.token = token

    def devices(self):
        FakeLivesky.calls.append("devices")
        return [{"imei": IMEI, "device_name": "River Motor"}]

    def motors(self, imei):
        FakeLivesky.calls.append("motors")
        assert imei == IMEI
        return [LIVE_ON]


def test_pull_writes_allow_listed_state():
    W.LiveskyClient, real = FakeLivesky, W.LiveskyClient
    FakeLivesky.calls = []
    try:
        db = DB({"private": {"livesky": {"token": "t", "exp": 2_000_000_000}}})
        out = W.pull(db, "farms/snof", "https://x", FakeNiagara(), now_s=1_900_000_000)
    finally:
        W.LiveskyClient = real
    water = db.data["farms"]["snof"]["water"]
    assert out["river"] and out["motors"] == 2
    assert water["river"]["running"] is True
    assert set(water["motors"]) == {"well-motor", "wellmotor75hp"}
    # The IMEI came from the account's own device list and stayed private.
    assert db.data["private"]["livesky"]["imei"] == IMEI and FakeLivesky.calls == ["devices", "motors"]
    no_secrets(water, "pulled water")
    meta = db.data["farms"]["snof"]["meta"]["water"]
    assert meta["livesky"]["ok"] is True and meta["niagara"]["ok"] is True
    assert meta["livesky"]["expires"] == 2_000_000_000 * 1000


def test_pull_expired_session_calls_nothing_and_keeps_last_state():
    W.LiveskyClient, real = FakeLivesky, W.LiveskyClient
    FakeLivesky.calls = []
    try:
        db = DB({"private": {"livesky": {"token": "t", "exp": 100, "imei": IMEI}},
                 "farms": {"snof": {"water": {"river": {"running": False, "name": "River Motor"}}}}})
        niagara = FakeNiagara(fail=True)
        out = W.pull(db, "farms/snof", "https://x", niagara, now_s=1_900_000_000)
    finally:
        W.LiveskyClient = real
    assert FakeLivesky.calls == [], "an expired Livesky session must not be used"
    assert out["livesky"] == "The Livesky session has expired."
    water = db.data["farms"]["snof"]["water"]
    assert water["river"] == {"running": False, "name": "River Motor"}, "last good state kept"
    assert "motors" not in water
    meta = db.data["farms"]["snof"]["meta"]["water"]
    assert meta["niagara"]["ok"] is False and "502" in meta["niagara"]["error"]


def test_pull_signed_out():
    db = DB()
    out = W.pull(db, "farms/snof", "https://x", None, now_s=1)
    assert out["livesky"] == "Not signed in to Livesky." and out["niagara"] == "Niagara is not configured."


def test_claim_pull_spacing():
    db = DB()
    assert W.claim_pull(db, "farms/snof", 1_000_000) is True
    assert W.claim_pull(db, "farms/snof", 1_005_000) is False, "a second pull 5 s later must wait"
    assert W.claim_pull(db, "farms/snof", 1_016_000) is True


if __name__ == "__main__":
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_")]
    for name, fn in tests:
        fn()
        print(f"ok  {name}")
    print(f"{len(tests)} passed")

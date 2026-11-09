#!/usr/bin/env python3
"""One-shot: token + usage-summary + pace preview (без GUI)."""
import base64
import json
import os
import socket
import sqlite3
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

DB = Path.home() / "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
CURSOR_SETTINGS = Path.home() / "Library/Application Support/Cursor/User/settings.json"
APP_SETTINGS = Path.home() / "Library/Application Support/cursor-usage-menubar/settings.json"
URL = "https://cursor.com/api/usage-summary"
PERIOD_URL = "https://cursor.com/api/dashboard/get-current-period-usage"


def jwt_sub(token: str) -> str:
    part = token.split(".")[1]
    part += "=" * (-len(part) % 4)
    payload = json.loads(base64.urlsafe_b64decode(part))
    return payload["sub"]


def parse_http_proxy(raw: str):
    raw = (raw or "").strip()
    if not raw:
        return None
    if "://" not in raw and ":" in raw:
        raw = "http://" + raw
    u = urllib.parse.urlparse(raw)
    if u.scheme not in ("http", "https") or not u.hostname:
        return None
    port = u.port or (443 if u.scheme == "https" else 80)
    return u.hostname, port


def tcp_open(host: str, port: int, timeout: float = 0.25) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


DEFAULT_SETTINGS = {"proxyMode": "auto", "proxyURL": "http://127.0.0.1:8080"}


def load_app_settings():
    if not APP_SETTINGS.is_file():
        return dict(DEFAULT_SETTINGS)
    try:
        return json.loads(APP_SETTINGS.read_text())
    except (OSError, json.JSONDecodeError):
        return dict(DEFAULT_SETTINGS)


def env_proxy():
    for key in ("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"):
        p = parse_http_proxy(os.environ.get(key, ""))
        if p:
            return p
    return None


def auto_candidates():
    seen = set()
    out = []
    raw = None
    if CURSOR_SETTINGS.is_file():
        try:
            raw = json.loads(CURSOR_SETTINGS.read_text()).get("http.proxy")
        except (OSError, json.JSONDecodeError):
            raw = None
    for item in (
        parse_http_proxy(raw) if isinstance(raw, str) else None,
        env_proxy(),
    ):
        if not item:
            continue
        key = f"{item[0]}:{item[1]}"
        if key in seen:
            continue
        seen.add(key)
        if tcp_open(item[0], item[1]):
            out.append(item)
    out.append(None)
    return out


def proxy_candidates():
    cfg = load_app_settings()
    mode = cfg.get("proxyMode") or "auto"
    if mode == "direct":
        return [None]
    if mode == "manual":
        p = parse_http_proxy(cfg.get("proxyURL") or "")
        return [p, None] if p else [None]
    return auto_candidates()


def fetch(cookie: str, proxy, url=URL, method="GET", body=None):
    headers = {"Cookie": cookie, "User-Agent": "CursorUsageMenubar-status/1.0"}
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else body.encode()
        headers["Content-Type"] = "application/json"
        headers["Origin"] = "https://cursor.com"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    if proxy:
        host, port = proxy
        handler = urllib.request.ProxyHandler(
            {"http": f"http://{host}:{port}", "https": f"http://{host}:{port}"}
        )
        opener = urllib.request.build_opener(handler)
        timeout = 15
        via = f"{host}:{port}"
    else:
        opener = urllib.request.build_opener()
        timeout = 8
        via = "direct"
    with opener.open(req, timeout=timeout) as r:
        return json.load(r), via


def main() -> None:
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    row = con.execute(
        "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'"
    ).fetchone()
    if not row:
        raise SystemExit("нет accessToken")
    token = row[0]
    sub = jwt_sub(token)
    cookie = "WorkosCursorSessionToken=" + urllib.parse.quote(f"{sub}::{token}", safe="")

    cfg = load_app_settings()
    last_err = None
    data = None
    via = None
    for proxy in proxy_candidates():
        try:
            data, via = fetch(cookie, proxy)
            break
        except Exception as e:  # noqa: BLE001
            last_err = e
            continue
    if data is None:
        raise SystemExit(f"не достучаться до cursor.com: {last_err}")

    period = None
    for proxy in proxy_candidates():
        try:
            period, via = fetch(cookie, proxy, url=PERIOD_URL, method="POST", body="{}")
            break
        except Exception as e:  # noqa: BLE001
            last_err = e
            continue

    plan = (data.get("individualUsage") or {}).get("plan") or {}
    summary_total = float(plan.get("totalPercentUsed") or 0)
    pu = (period or {}).get("planUsage") or {}
    if pu.get("totalPercentUsed") is not None:
        total = float(pu["totalPercentUsed"])
        auto = float(pu.get("autoPercentUsed") if pu.get("autoPercentUsed") is not None else total)
        api = pu.get("apiPercentUsed")
        start = datetime.fromtimestamp(int(period["billingCycleStart"]) / 1000, tz=timezone.utc)
        end = datetime.fromtimestamp(int(period["billingCycleEnd"]) / 1000, tz=timezone.utc)
        source = "current-period"
    else:
        total = summary_total
        auto = float(plan.get("autoPercentUsed") or 0)
        api = plan.get("apiPercentUsed")
        start = datetime.fromisoformat(data["billingCycleStart"].replace("Z", "+00:00"))
        end = datetime.fromisoformat(data["billingCycleEnd"].replace("Z", "+00:00"))
        source = "usage-summary"
    now = datetime.now(timezone.utc)
    frac = min(1.0, max(0.0, (now - start).total_seconds() / (end - start).total_seconds()))
    api_txt = "нет отдельной квоты" if api is None else f"{float(api):.1f}%"
    print(
        f"OK  mode={cfg.get('proxyMode')} via={via}  plan={data.get('membershipType')}  "
        f"source={source}  total={total:.1f}%  auto={auto:.1f}%  api/other={api_txt}"
    )
    print(
        f"    summary-raw={summary_total:.1f}%  expected≈{frac*100:.1f}%  "
        f"cycle {start.date()} → {end.date()}"
    )
    if total > frac * 100 + 5:
        print("    pace: выше графика")
    elif total < frac * 100 - 5:
        print("    pace: ниже графика")
    else:
        print("    pace: в графике")


if __name__ == "__main__":
    main()

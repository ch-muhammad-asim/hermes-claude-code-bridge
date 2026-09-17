#!/usr/bin/env python3
"""Read-only Prometheus + Alertmanager MCP for the Hermes agent.

Stdio MCP. Talks only to the two in-cluster HTTP endpoints named by PROMETHEUS_URL and
ALERTMANAGER_URL, GET requests only, no auth (the defaults are the ClusterIP services of a
kube-prometheus-stack install in the `monitoring` namespace). Every result is bounded so a wide
query cannot flood the model. Stdlib only.

Tools:
  prom_query(query, time=None)                 instant PromQL
  prom_query_range(query, start, end, step)    range PromQL (RFC3339 or unix seconds; relative like -1h ok)
  prom_alerts()                                alerts as Prometheus evaluates them (firing/pending)
  prom_targets_down()                          scrape targets whose health != up
  alertmanager_alerts(active_only=True)        alerts as Alertmanager holds them (silenced/inhibited state)
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    from mcp.server.mcpserver import MCPServer as _ServerClass  # Hermes >= v0.20.3
    _USE_RUN_KWARGS = True
except ImportError:  # pragma: no cover
    from mcp.server.fastmcp import FastMCP as _ServerClass  # Hermes <= v0.20.2
    _USE_RUN_KWARGS = False

PROM = os.environ.get("PROMETHEUS_URL", "http://prometheus-kube-prometheus-prometheus.monitoring.svc:9090").rstrip("/")
AM = os.environ.get("ALERTMANAGER_URL", "http://prometheus-kube-prometheus-alertmanager.monitoring.svc:9093").rstrip("/")
TIMEOUT = int(os.environ.get("PROM_MCP_TIMEOUT", "30"))
MAX_CHARS = int(os.environ.get("PROM_MCP_MAX_CHARS", "30000"))
MAX_SERIES = int(os.environ.get("PROM_MCP_MAX_SERIES", "200"))
MAX_POINTS = int(os.environ.get("PROM_MCP_MAX_POINTS", "400"))

mcp = _ServerClass("prometheus-readonly")


def _get(base: str, path: str, params: dict | None = None):
    url = base + path + (("?" + urllib.parse.urlencode({k: v for k, v in (params or {}).items() if v is not None})) if params else "")
    req = urllib.request.Request(url, method="GET", headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        body = exc.read()[:800].decode("utf-8", "replace")
        raise RuntimeError(f"HTTP {exc.code} from {base}{path}: {body}")


def _ts(value):
    """Accept unix seconds, RFC3339, or relative '-15m' / '-2h' / 'now'."""
    if value is None:
        return None
    text = str(value).strip()
    if text in ("", "now"):
        return str(time.time())
    m = re.fullmatch(r"-(\d+)([smhd])", text)
    if m:
        mult = {"s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]
        return str(time.time() - int(m.group(1)) * mult)
    return text


def _bounded(payload) -> str:
    text = json.dumps(payload, indent=1, default=str)
    if len(text) > MAX_CHARS:
        return json.dumps({"truncated": True, "excerpt": text[:MAX_CHARS],
                           "note": "Result truncated; narrow the query (labels, time range, step)."})
    return text


@mcp.tool()
def prom_query(query: str, time: str | None = None) -> str:
    """Instant PromQL query against the development Prometheus (read-only).
    `time` optional: unix seconds, RFC3339, or relative like '-5m'. Returns up to 200 series."""
    data = _get(PROM, "/api/v1/query", {"query": query, "time": _ts(time)})
    result = data.get("data", {}).get("result", [])
    return _bounded({"resultType": data.get("data", {}).get("resultType"), "series": len(result),
                     "result": result[:MAX_SERIES], "truncated_series": len(result) > MAX_SERIES,
                     "warnings": data.get("warnings")})


@mcp.tool()
def prom_query_range(query: str, start: str = "-1h", end: str = "now", step: str = "60s") -> str:
    """Range PromQL query (read-only). start/end: unix seconds, RFC3339, or relative ('-1h', 'now').
    step like '30s', '5m'. Series are capped at 200 and each series at 400 points."""
    data = _get(PROM, "/api/v1/query_range", {"query": query, "start": _ts(start), "end": _ts(end), "step": step})
    result = data.get("data", {}).get("result", [])
    trimmed = []
    for series in result[:MAX_SERIES]:
        values = series.get("values", [])
        trimmed.append({"metric": series.get("metric"), "points": len(values),
                        "values": values[-MAX_POINTS:], "truncated_points": len(values) > MAX_POINTS})
    return _bounded({"series": len(result), "result": trimmed, "truncated_series": len(result) > MAX_SERIES,
                     "warnings": data.get("warnings")})


@mcp.tool()
def prom_alerts() -> str:
    """Alerts as evaluated by Prometheus rules right now: state (firing/pending), labels, annotations, activeAt."""
    data = _get(PROM, "/api/v1/alerts")
    alerts = data.get("data", {}).get("alerts", [])
    alerts.sort(key=lambda a: (a.get("state") != "firing", a.get("labels", {}).get("severity", "")))
    return _bounded({"total": len(alerts), "firing": sum(1 for a in alerts if a.get("state") == "firing"),
                     "alerts": alerts[:MAX_SERIES]})


@mcp.tool()
def prom_targets_down() -> str:
    """Scrape targets whose health is not 'up', with the last error and scrape URL (read-only)."""
    data = _get(PROM, "/api/v1/targets", {"state": "active"})
    targets = data.get("data", {}).get("activeTargets", [])
    down = [{"job": t.get("labels", {}).get("job"), "instance": t.get("labels", {}).get("instance"),
             "namespace": t.get("labels", {}).get("namespace"), "pod": t.get("labels", {}).get("pod"),
             "health": t.get("health"), "lastError": (t.get("lastError") or "")[:300],
             "lastScrape": t.get("lastScrape"), "scrapeUrl": t.get("scrapeUrl")}
            for t in targets if t.get("health") != "up"]
    return _bounded({"active_targets": len(targets), "down": len(down), "targets": down[:MAX_SERIES]})


@mcp.tool()
def alertmanager_alerts(active_only: bool = True) -> str:
    """Alerts as held by Alertmanager, including silenced/inhibited status and receivers (read-only)."""
    params = {"active": "true"} if active_only else {"active": "true", "silenced": "true", "inhibited": "true"}
    alerts = _get(AM, "/api/v2/alerts", params)
    slim = [{"labels": a.get("labels"), "state": (a.get("status") or {}).get("state"),
             "silencedBy": (a.get("status") or {}).get("silencedBy"), "inhibitedBy": (a.get("status") or {}).get("inhibitedBy"),
             "startsAt": a.get("startsAt"), "receivers": [r.get("name") for r in a.get("receivers", [])],
             "summary": (a.get("annotations") or {}).get("summary") or (a.get("annotations") or {}).get("description")}
            for a in alerts]
    return _bounded({"total": len(slim), "alerts": slim[:MAX_SERIES]})


if __name__ == "__main__":
    sys.stderr.write(f"[prom-mcp] prometheus={PROM} alertmanager={AM}\n")
    mcp.run(transport="stdio")

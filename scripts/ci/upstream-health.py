#!/usr/bin/env python3
"""Upstream health: find dependencies whose upstream is dead, moved or EOL.

Renovate only reports new versions. An upstream that stops releasing, gets
archived, renamed or deleted looks exactly like "up to date". This script
reads a Renovate report (`--report-type=file`, see upstream-health.sh) and
checks every dependency's source repository plus its release cycle:

  archived      GitHub/Gitea repo is archived
  not-found     source repo is gone (deleted, made private)
  renamed       repo was renamed or transferred (GitHub redirects silently)
  inactive      no commit on the default branch for `thresholdDays`
  no-release    no release/tag for `thresholdDays` (repo itself may be active)
  frozen        image comes from a registry that is known to be frozen
  lookup-failed Renovate could not look the package up at all
  eol / eol-soon  release cycle EOL per endoflife.date

Usage: upstream-health.py <report.json> <config.json> <out.md>
Env:   GITHUB_TOKEN (required for the GitHub GraphQL API)
Stdlib only, so it runs on a bare runner.
"""
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.request

NOW = dt.datetime.now(dt.timezone.utc)
KIND_ORDER = ["archived", "not-found", "frozen", "eol", "lookup-failed",
              "renamed", "inactive", "no-release", "eol-soon"]
KIND_LABEL = {
    "archived": "Archiviert",
    "not-found": "Quelle verschwunden",
    "frozen": "Eingefrorene Registry",
    "eol": "End of Life",
    "lookup-failed": "Renovate-Lookup scheitert",
    "renamed": "Umbenannt / umgezogen",
    "inactive": "Keine Commits",
    "no-release": "Keine Releases",
    "eol-soon": "EOL bald",
}
REPO_RE = re.compile(r"https?://(?:https?://)?(github\.com|codeberg\.org|code\.forgejo\.org)/([^/\s]+)/([^/\s#?]+)")


def http_json(url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=headers or {})
    req.add_header("User-Agent", "homelab-upstream-health")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def parse_ts(value):
    if not value:
        return None
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def age_days(ts):
    return (NOW - ts).days if ts else None


def load_deps(report):
    """Flatten the report into one record per (repo-in-report, depName)."""
    deps = {}
    for repo_name, repo in report.get("repositories", {}).items():
        for manager, files in repo.get("packageFiles", {}).items():
            for pf in files:
                for d in pf.get("deps", []):
                    if d.get("skipReason") or d.get("datasource") in (None, "kubernetes-api"):
                        continue
                    key = d.get("packageName") or d["depName"]
                    rec = deps.setdefault(key, {
                        "name": key, "datasource": d.get("datasource"),
                        "version": d.get("currentVersion") or d.get("currentValue"),
                        "sourceUrl": d.get("sourceUrl"), "files": set(),
                        "mostRecentTimestamp": d.get("mostRecentTimestamp"),
                        "warnings": [],
                    })
                    rec["files"].add(pf["packageFile"])
                    rec["sourceUrl"] = rec["sourceUrl"] or d.get("sourceUrl")
                    for w in d.get("warnings") or []:
                        if w["message"] not in rec["warnings"]:
                            rec["warnings"].append(w["message"])
    return deps


def source_of(dep, overrides):
    url = overrides.get(dep["name"]) or dep["sourceUrl"] or ""
    if not url.startswith("http"):
        url = "https://" + url if url else ""
    m = REPO_RE.match(url)
    if m:
        return m.group(1), m.group(2), re.sub(r"\.git$", "", m.group(3))
    # github-releases/-tags packageName is the repo itself
    if dep["datasource"] in ("github-releases", "github-tags") and dep["name"].count("/") == 1:
        owner, name = dep["name"].split("/")
        return "github.com", owner, name
    return None


GQL_FIELDS = """nameWithOwner isArchived archivedAt url
  defaultBranchRef { target { ... on Commit { committedDate } } }
  latestRelease { publishedAt tagName }
  refs(refPrefix: "refs/tags/", first: 1, orderBy: {field: TAG_COMMIT_DATE, direction: DESC}) {
    nodes { name target { ... on Commit { committedDate } ... on Tag { target { ... on Commit { committedDate } } } } } }"""


def github_lookup(repos, token):
    """repos: list of (owner, name). Returns {(owner,name): info|None}."""
    out = {}
    for i in range(0, len(repos), 40):
        chunk = repos[i:i + 40]
        parts = [f'r{j}: repository(owner: {json.dumps(o)}, name: {json.dumps(n)}) {{ {GQL_FIELDS} }}'
                 for j, (o, n) in enumerate(chunk)]
        body = json.dumps({"query": "{ " + "\n".join(parts) + " }"}).encode()
        res = http_json("https://api.github.com/graphql", body,
                        {"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
        not_found = {e["path"][0] for e in res.get("errors", []) if e.get("type") == "NOT_FOUND"}
        other = [e for e in res.get("errors", []) if e.get("type") != "NOT_FOUND"]
        if other:
            raise RuntimeError(f"GitHub GraphQL error: {other[0].get('message')}")
        for j, key in enumerate(chunk):
            node = (res.get("data") or {}).get(f"r{j}")
            if node is None:
                out[key] = None if f"r{j}" in not_found else {"error": True}
                continue
            tag = (node["refs"]["nodes"] or [None])[0]
            tag_ts = None
            if tag:
                t = tag["target"]
                tag_ts = t.get("committedDate") or (t.get("target") or {}).get("committedDate")
            release_ts = max(filter(None, [(node["latestRelease"] or {}).get("publishedAt"), tag_ts]), default=None)
            out[key] = {
                "fullName": node["nameWithOwner"], "archived": node["isArchived"],
                "archivedAt": node["archivedAt"], "url": node["url"],
                "lastCommit": ((node["defaultBranchRef"] or {}).get("target") or {}).get("committedDate"),
                "lastRelease": release_ts,
            }
    return out


def gitea_lookup(host, owner, name):
    try:
        r = http_json(f"https://{host}/api/v1/repos/{owner}/{name}")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        return {"error": True}
    except (urllib.error.URLError, TimeoutError):
        return {"error": True}
    commit = None
    try:
        c = http_json(f"https://{host}/api/v1/repos/{owner}/{name}/commits?limit=1&stat=false&verification=false&files=false")
        commit = c[0]["created"] if c else None
    except (urllib.error.URLError, TimeoutError, KeyError, IndexError):
        pass
    return {"fullName": r["full_name"], "archived": r.get("archived", False),
            "archivedAt": r.get("archived_at"), "url": r["html_url"],
            "lastCommit": commit, "lastRelease": None}


def eol_lookup(product, version, cache):
    nums = re.findall(r"\d+", version or "")
    candidates = [".".join(nums[:2]), nums[0]] if len(nums) >= 2 else nums[:1]
    for cycle in candidates:
        key = (product, cycle)
        if key not in cache:
            try:
                cache[key] = http_json(f"https://endoflife.date/api/v1/products/{product}/releases/{cycle}")["result"]
            except urllib.error.HTTPError as e:
                cache[key] = None if e.code == 404 else {"error": True}
            except (urllib.error.URLError, TimeoutError):
                cache[key] = {"error": True}
        if cache[key] is not None:
            return cycle, cache[key]
    return None, None


def ignored(finding, rules):
    for r in rules:
        if r.get("kinds") and finding["kind"] not in r["kinds"]:
            continue
        if re.search(r["match"], finding["dep"]) or re.search(r["match"], finding.get("repo") or "\0"):
            return r["reason"]
    return None


def main(report_path, config_path, out_path):
    report = json.load(open(report_path))
    cfg = json.load(open(config_path))
    threshold = cfg.get("thresholdDays", 365)
    eol_warn = cfg.get("eolWarnDays", 90)
    token = os.environ.get("GITHUB_TOKEN") or sys.exit("GITHUB_TOKEN not set")

    deps = load_deps(report)
    findings, unchecked, notes = [], [], []

    def add(kind, dep, detail, repo=None):
        findings.append({"kind": kind, "dep": dep["name"], "repo": repo, "detail": detail,
                         "files": sorted(dep["files"])})

    # Source repositories
    sources = {}
    for dep in deps.values():
        src = source_of(dep, cfg.get("sources", {}))
        if src:
            sources.setdefault(src, []).append(dep)
        elif dep["datasource"] not in cfg.get("skipDatasources", []):
            unchecked.append(dep["name"])
    gh_keys = sorted({(o, n) for (h, o, n) in sources if h == "github.com"})
    gh = github_lookup(gh_keys, token)
    for (host, owner, name), ds in sorted(sources.items()):
        info = gh.get((owner, name)) if host == "github.com" else gitea_lookup(host, owner, name)
        repo = f"{host}/{owner}/{name}"
        for dep in ds:
            if info is None:
                add("not-found", dep, f"`{repo}` existiert nicht (gelöscht oder privat)", repo)
                continue
            if info.get("error"):
                notes.append(f"`{repo}`: Abfrage fehlgeschlagen, nicht geprüft")
                continue
            if info["archived"]:
                since = f" seit {info['archivedAt'][:10]}" if info.get("archivedAt") else ""
                add("archived", dep, f"[{info['fullName']}]({info['url']}) archiviert{since}", repo)
                continue
            if info["fullName"].lower() != f"{owner}/{name}".lower():
                add("renamed", dep, f"`{owner}/{name}` → [{info['fullName']}]({info['url']})", repo)
            commit_age = age_days(parse_ts(info["lastCommit"]))
            if commit_age is not None and commit_age > threshold:
                add("inactive", dep, f"letzter Commit vor {commit_age} Tagen ({info['lastCommit'][:10]})", repo)
            elif info.get("lastRelease"):
                rel_age = age_days(parse_ts(info["lastRelease"]))
                if rel_age > threshold:
                    add("no-release", dep, f"letztes Release/Tag vor {rel_age} Tagen ({info['lastRelease'][:10]}), Repo aber aktiv", repo)

    # Renovate's own signals
    for dep in deps.values():
        for msg in dep["warnings"]:
            if "Failed to look up" in msg:
                add("lookup-failed", dep, msg)
        ts = parse_ts(dep["mostRecentTimestamp"])
        if ts and age_days(ts) > threshold and not any(f["dep"] == dep["name"] and f["kind"] in ("inactive", "no-release", "archived") for f in findings):
            add("no-release", dep, f"neuestes Release laut Renovate vor {age_days(ts)} Tagen ({dep['mostRecentTimestamp'][:10]})")
        for rule in cfg.get("frozen", []):
            if re.search(rule["match"], dep["name"]):
                add("frozen", dep, rule["reason"])

    # EOL per endoflife.date
    eol_cache = {}
    for dep in deps.values():
        for rule in cfg.get("eol", []):
            if rule.get("datasource") and rule["datasource"] != dep["datasource"]:
                continue
            if not re.search(rule["match"], dep["name"]):
                continue
            cycle, rel = eol_lookup(rule["product"], dep["version"], eol_cache)
            if rel is None:
                notes.append(f"`{dep['name']}` {dep['version']}: kein Zyklus bei endoflife.date/{rule['product']}")
            elif rel.get("error"):
                notes.append(f"endoflife.date/{rule['product']}: Abfrage fehlgeschlagen")
            elif rel.get("isEol"):
                add("eol", dep, f"{rule['product']} {cycle} EOL seit {rel.get('eolFrom')}")
            elif rel.get("eolFrom"):
                left = (dt.date.fromisoformat(rel["eolFrom"]) - NOW.date()).days
                if left <= eol_warn:
                    add("eol-soon", dep, f"{rule['product']} {cycle} EOL am {rel['eolFrom']} (in {left} Tagen)")
            break

    active, accepted = [], []
    for f in findings:
        reason = ignored(f, cfg.get("ignore", []))
        (accepted if reason else active).append({**f, "reason": reason})
    active.sort(key=lambda f: (KIND_ORDER.index(f["kind"]), f["dep"]))

    lines = [f"Wöchentlicher Check aller Renovate-Dependencies auf tote, umgezogene und EOL-Upstreams "
             f"(Schwelle {threshold} Tage). Stand: {NOW:%Y-%m-%d %H:%M} UTC.", ""]
    if not active:
        lines += ["**Keine offenen Befunde.**", ""]
    for kind in KIND_ORDER:
        rows = [f for f in active if f["kind"] == kind]
        if not rows:
            continue
        lines += [f"### {KIND_LABEL[kind]} ({len(rows)})", "", "| Dependency | Befund | Dateien |", "|---|---|---|"]
        for f in rows:
            lines.append(f"| `{f['dep']}` | {f['detail']} | {'<br>'.join(f['files'])} |")
        lines.append("")
    if accepted:
        lines += ["<details><summary>Akzeptiert per Ignore-Liste (" + str(len(accepted)) + ")</summary>", ""]
        lines += [f"- `{f['dep']}` — {KIND_LABEL[f['kind']]}: {f['reason']}" for f in accepted]
        lines += ["", "</details>", ""]
    if unchecked or notes:
        lines += [f"<details><summary>Nicht prüfbar ({len(unchecked) + len(notes)})</summary>", "",
                  "Kein Quell-Repo bekannt — in `scripts/ci/upstream-health.json` unter `sources` nachtragen:", ""]
        lines += [f"- `{u}`" for u in sorted(unchecked)] + [f"- {n}" for n in notes]
        lines += ["", "</details>", ""]
    # Keys drive the "new findings" comment. Lookup failures are often
    # transient (registry rate limits), so they show in the body but never
    # notify on their own.
    keys = sorted({f"{f['kind']}:{f['dep']}" for f in active if f["kind"] != "lookup-failed"})
    lines.append(f"<!-- upstream-health-keys: {json.dumps(keys)} -->")
    open(out_path, "w").write("\n".join(lines) + "\n")
    print(f"{len(deps)} deps, {len(sources)} source repos, {len(active)} findings, "
          f"{len(accepted)} accepted, {len(unchecked)} unchecked")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])

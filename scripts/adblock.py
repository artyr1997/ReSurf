#!/usr/bin/env python3
"""Turns EasyList + EasyPrivacy into a WebKit content rule list (src-tauri/adblock.json).

    python3 scripts/adblock.py            # downloads the lists
    python3 scripts/adblock.py a.txt b.txt

Only what WebKit can say exactly is kept: address rules (`||ads.example^`, `/banner/*`) with their
type, party and site options, `@@` exceptions, and element hiding (`##.ad`, `site.com##.ad`).
Scriptlets, procedural selectors, regex rules and options like $redirect or $csp are left out:
half a rule would block the wrong things.
"""

import json
import re
import sys
import urllib.request
from collections import defaultdict
from pathlib import Path

LISTS = [
    "https://easylist.to/easylist/easylist.txt",
    "https://easylist.to/easylist/easyprivacy.txt",
]
OUT = Path(__file__).resolve().parent.parent / "src-tauri" / "adblock.json"

TYPES = {
    "script": ["script"],
    "image": ["image"],
    "stylesheet": ["style-sheet"],
    "font": ["font"],
    "media": ["media"],
    "xmlhttprequest": ["fetch"],
    "subdocument": ["document"],
    "ping": ["ping"],
    "websocket": ["websocket"],
    "popup": ["popup"],
    "other": ["other"],
    "object": ["other"],
}
# what a rule without types covers (frames are documents inside the page; popups are left alone)
ALL_TYPES = sorted({t for ts in TYPES.values() for t in ts} - {"popup"})
# options that change nothing WebKit could do differently
HARMLESS = {"important", "match-case", "third-party", "3p", "first-party", "1p", "~third-party", "~first-party"}
# selectors WebKit's CSS parser won't take, or that need a script
PROCEDURAL = re.compile(r":-abp-|:has-text|:contains|:xpath|:upward|:remove|:style\(|:matches-|:min-text|"
                        r":watch-attr|:others|:if|\[-ext-|:matches-path|:nth-ancestor|:has\(|:not\(.*:has")

SEPARATOR = "[^a-zA-Z0-9_.%-]"


def url_filter(pattern):
    """An address pattern in Adblock syntax as the regex subset WebKit accepts, or None."""
    if not pattern.isascii() or (pattern.startswith("/") and pattern.endswith("/") and len(pattern) > 1):
        return None
    out = ""
    if pattern.startswith("||"):
        out = "^[htpsw]+://([a-z0-9-]+\\.)*"  # http(s), ws(s), any subdomain
        pattern = pattern[2:]
    elif pattern.startswith("|"):
        out = "^"
        pattern = pattern[1:]
    end = ""
    if pattern.endswith("|"):
        end = "$"
        pattern = pattern[:-1]
    for c in pattern:
        if c == "*":
            out += ".*"
        elif c == "^":
            # also "or the end" in Adblock syntax; left out, as it makes WebKit compile ten times slower,
            # and after a domain there is always a "/" anyway
            out += SEPARATOR
        elif c in ".+?()[]{}\\$|":
            out += "\\" + c
        else:
            out += c
    out += end
    if out in ("", "^", ".*"):
        return None
    return out


def domains(spec):
    """`a.com|~b.com` → (if-domain, unless-domain), WebKit style (`*a.com` also covers subdomains)."""
    yes, no = [], []
    for d in spec.lower().split("|"):
        d = d.strip()
        if not d or not d.lstrip("~").isascii() or "*" in d or "/" in d:
            continue
        (no if d.startswith("~") else yes).append("*" + d.lstrip("~"))
    return yes, no


def network(line):
    exception = line.startswith("@@")
    if exception:
        line = line[2:]
    pattern, dollar, opts = line.rpartition("$")
    if not dollar:
        pattern, opts = line, ""
    trigger = {}
    types, not_types = [], []
    page_exception = False
    for opt in filter(None, opts.split(",")):
        name, _, value = opt.partition("=")
        name = name.strip().lower()
        if name in ("third-party", "3p"):
            trigger["load-type"] = ["third-party"]
        elif name in ("~third-party", "first-party", "1p"):
            trigger["load-type"] = ["first-party"]
        elif name == "match-case":
            trigger["url-filter-is-case-sensitive"] = True
        elif name == "domain":
            yes, no = domains(value)
            if yes and no:
                return None
            if yes:
                trigger["if-domain"] = yes
            if no:
                trigger["unless-domain"] = no
        elif name.lstrip("~") in TYPES:
            (not_types if name.startswith("~") else types).extend(TYPES[name.lstrip("~")])
        elif name == "document" and exception:
            page_exception = True
        elif name in HARMLESS:
            pass
        else:
            return None  # $redirect, $csp, $removeparam, $generichide, …
    if page_exception:
        # @@||site^$document: nothing is blocked on that site
        site = pattern.strip("|^").split("/")[0]
        if not re.fullmatch(r"[a-z0-9.-]+", site):
            return None
        return [{"trigger": {"url-filter": ".*", "if-domain": ["*" + site]}, "action": {"type": "ignore-previous-rules"}}]
    regex = url_filter(pattern)
    if regex is None:
        return None
    trigger = {"url-filter": regex, **trigger}
    if not_types and not types:
        types = [t for t in ALL_TYPES if t not in not_types]
    action = {"type": "ignore-previous-rules" if exception else "block"}
    if not types:
        return [{"trigger": trigger, "action": action}]
    # a frame is a "document" loaded inside the page; the page itself must never be matched
    rules = []
    others = sorted(set(types) - {"document"})
    if others:
        rules.append({"trigger": {**trigger, "resource-type": others}, "action": action})
    if "document" in types:
        rules.append({"trigger": {**trigger, "resource-type": ["document"], "load-context": ["child-frame"]},
                      "action": action})
    return rules


def convert(lines):
    blocks, exceptions = [], []
    generic = []  # selectors hidden everywhere
    scoped = defaultdict(list)  # (if, unless) → selectors
    allowed = defaultdict(list)  # selector → sites where it must stay visible
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith(("!", "[")):
            continue
        if "#@#" in line:
            sites, _, selector = line.partition("#@#")
            allowed[selector].extend(domains(sites.replace(",", "|"))[0])
            continue
        if "##" in line:
            sites, _, selector = line.partition("##")
            if PROCEDURAL.search(selector) or not selector.isascii() or "+js(" in selector:
                continue
            if not sites:
                generic.append(selector)
                continue
            yes, no = domains(sites.replace(",", "|"))
            if yes and no:
                continue
            if yes or no:
                scoped[(tuple(yes), tuple(no))].append(selector)
            continue
        if re.search(r"#[?$%@]#|#\+js", line):
            continue
        for rule in network(line) or []:
            (exceptions if rule["action"]["type"] == "ignore-previous-rules" else blocks).append(rule)

    hiding = []

    def hide(selectors, trigger):
        selectors = sorted(set(selectors))
        for i in range(0, len(selectors), 250):
            hiding.append({"trigger": {"url-filter": ".*", **trigger},
                           "action": {"type": "css-display-none", "selector": ", ".join(selectors[i:i + 250])}})

    hide([s for s in generic if s not in allowed], {})
    for s in sorted(set(generic) & set(allowed)):
        sites = sorted(set(allowed[s]))
        hide([s], {"unless-domain": sites} if sites else {})
    for (yes, no), selectors in sorted(scoped.items()):
        hide(selectors, {"if-domain": list(yes)} if yes else {"unless-domain": list(no)})
    # exceptions last: ignore-previous-rules only undoes the rules before it
    return blocks + hiding + exceptions


def main():
    paths = sys.argv[1:]
    lines = []
    if paths:
        for p in paths:
            lines += Path(p).read_text(encoding="utf-8").splitlines()
    else:
        for url in LISTS:
            with urllib.request.urlopen(url) as r:
                lines += r.read().decode("utf-8").splitlines()
    rules = convert(lines)
    OUT.write_text(json.dumps(rules, separators=(",", ":")))
    print(f"{len(rules)} rules → {OUT} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()

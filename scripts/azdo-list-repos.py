#!/usr/bin/env python3
"""List git repos in an Azure DevOps project as TSV.

Output columns: repo_name <TAB> instance_name <TAB> clone_url <TAB> size_bytes
Instance names are sanitized to match scripts/lib.sh instance_name().

PAT is read from $AZDO_PAT, else ~/.config/azdo/pat. It is never printed and
never placed on a command line.
"""
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

ORG = os.environ.get("AZDO_ORG", "")
PROJECT = os.environ.get("AZDO_PROJECT", "")
PAT_FILE = os.path.expanduser(os.environ.get("AZDO_PAT_FILE", "~/.config/azdo/pat"))

if not ORG or not PROJECT:
    sys.exit("error: set AZDO_ORG and AZDO_PROJECT (https://dev.azure.com/<org>/<project>)")


def read_pat() -> str:
    pat = os.environ.get("AZDO_PAT")
    if not pat:
        try:
            with open(PAT_FILE) as fh:
                pat = fh.read()
        except OSError as exc:
            sys.exit(f"error: no PAT in $AZDO_PAT and cannot read {PAT_FILE}: {exc}")
    pat = pat.strip()
    if not pat:
        sys.exit("error: PAT is empty")
    return pat


def sanitize(name: str) -> str:
    """Mirror lib.sh instance_name(): lowercase, [a-z0-9-] only, collapsed."""
    s = re.sub(r"[^a-z0-9-]+", "-", name.lower())
    s = re.sub(r"-{2,}", "-", s).strip("-")
    if not s or s[0].isdigit():
        s = "r-" + s
    return s[:63].rstrip("-")


def clean_url(url: str) -> str:
    """Strip any userinfo (org@) so git's credential helper isn't second-guessed."""
    parts = urllib.parse.urlsplit(url)
    netloc = parts.netloc.rsplit("@", 1)[-1]
    return urllib.parse.urlunsplit(parts._replace(netloc=netloc))


def main() -> None:
    pat = read_pat()
    url = (
        f"https://dev.azure.com/{urllib.parse.quote(ORG)}/"
        f"{urllib.parse.quote(PROJECT)}/_apis/git/repositories?api-version=7.1"
    )
    req = urllib.request.Request(url)
    req.add_header(
        "Authorization", "Basic " + base64.b64encode(f":{pat}".encode()).decode()
    )
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            repos = json.load(resp).get("value", [])
    except urllib.error.HTTPError as exc:
        hint = {
            401: "PAT rejected (bad/expired, or missing Code:Read)",
            203: "PAT rejected (non-interactive auth refused)",
            404: f"project {PROJECT!r} not found in org {ORG!r}",
        }.get(exc.code, "")
        sys.exit(f"error: HTTP {exc.code} {exc.reason} {hint}")
    except urllib.error.URLError as exc:
        sys.exit(f"error: cannot reach dev.azure.com: {exc.reason}")

    seen: dict[str, str] = {}
    for repo in sorted(repos, key=lambda r: r["name"].lower()):
        # Skip disabled repos and repos with no commits (no default branch).
        if repo.get("isDisabled") or repo.get("defaultBranch") is None:
            print(f"note: skipping {repo['name']} (disabled or empty)", file=sys.stderr)
            continue
        inst = sanitize(repo["name"])
        if inst in seen:  # de-collide deterministically
            n = 2
            while f"{inst}-{n}" in seen:
                n += 1
            print(
                f"note: {repo['name']} collides with {seen[inst]} -> {inst}-{n}",
                file=sys.stderr,
            )
            inst = f"{inst}-{n}"
        seen[inst] = repo["name"]
        url = clean_url(repo.get("remoteUrl") or repo.get("sshUrl", ""))
        print(f"{repo['name']}\t{inst}\t{url}\t{repo.get('size') or 0}")


if __name__ == "__main__":
    main()

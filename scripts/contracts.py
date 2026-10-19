#!/usr/bin/env python3
"""Vendored copy of RHServer contracts/: sync it at a commit, or check it.

    scripts/contracts.py sync <rhserver-commit>   replace contracts/ with RHServer's at that commit
    scripts/contracts.py check [--offline]        verify contracts/ against MANIFEST.sha256, UPSTREAM
                                                  and (unless --offline) RHServer at the UPSTREAM commit

contracts/MANIFEST.sha256 comes from RHServer: "<sha256>  <path>" per file, sorted by path,
the manifest itself not listed. contracts/UPSTREAM is written here at sync time:
    rhserver_commit=<full sha>
    manifest_sha256=<sha256 of MANIFEST.sha256>
Python 3.9 compatible (system python3 on macOS).
"""
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTRACTS = os.path.join(ROOT, "contracts")
REPO = os.environ.get("RH_SERVER_REPO", "https://github.com/ilyxas/RHServer.git")
LOCAL_ONLY = {"MANIFEST.sha256", "UPSTREAM"}


def sha256_file(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def list_files(directory):
    found = []
    for base, dirs, files in os.walk(directory):
        dirs[:] = [d for d in dirs if d != ".git"]
        for name in files:
            if name == ".DS_Store":
                continue
            rel = os.path.relpath(os.path.join(base, name), directory).replace(os.sep, "/")
            if rel not in LOCAL_ONLY:
                found.append(rel)
    return sorted(found)


def verify_manifest(directory):
    """Return a list of problems; empty means every file matches MANIFEST.sha256."""
    manifest_path = os.path.join(directory, "MANIFEST.sha256")
    if not os.path.isfile(manifest_path):
        return ["no MANIFEST.sha256"]
    problems, expected, order = [], {}, []
    with open(manifest_path, encoding="utf-8") as f:
        for line in f.read().splitlines():
            if not line:
                continue
            digest, sep, path = line.partition("  ")
            if not sep or len(digest) != 64:
                problems.append("malformed manifest line: %r" % line)
                continue
            expected[path] = digest
            order.append(path)
    if order != sorted(order):
        problems.append("MANIFEST.sha256 is not sorted by path")
    actual = list_files(directory)
    for path in sorted(set(actual) - set(expected)):
        problems.append("not in manifest: " + path)
    for path in sorted(set(expected) - set(actual)):
        problems.append("missing file: " + path)
    for path in sorted(set(actual) & set(expected)):
        if sha256_file(os.path.join(directory, path)) != expected[path]:
            problems.append("sha256 differs: " + path)
    return problems


def read_upstream():
    fields = {}
    with open(os.path.join(CONTRACTS, "UPSTREAM"), encoding="utf-8") as f:
        for line in f.read().splitlines():
            key, sep, value = line.partition("=")
            if sep:
                fields[key] = value
    return fields


def fetch(ref, into):
    """Shallow-fetch RHServer at ref (commit sha or branch) into an empty directory; return full sha."""
    def git(*args):
        return subprocess.run(["git", "-C", into] + list(args), check=True,
                              stdout=subprocess.PIPE, universal_newlines=True).stdout.strip()
    git("init", "-q")
    git("fetch", "-q", "--depth", "1", REPO, ref)
    git("checkout", "-q", "FETCH_HEAD")
    return git("rev-parse", "HEAD")


def sync(ref):
    tmp = tempfile.mkdtemp(prefix="rh-contracts-")
    try:
        full = fetch(ref, tmp)
        upstream = os.path.join(tmp, "contracts")
        problems = verify_manifest(upstream)
        if problems:
            sys.exit("RHServer contracts/ at %s fail their own manifest:\n  %s" % (full, "\n  ".join(problems)))
        shutil.rmtree(CONTRACTS, ignore_errors=True)
        shutil.copytree(upstream, CONTRACTS, ignore=shutil.ignore_patterns(".DS_Store"))
        with open(os.path.join(CONTRACTS, "UPSTREAM"), "w", encoding="utf-8") as f:
            f.write("rhserver_commit=%s\nmanifest_sha256=%s\n"
                    % (full, sha256_file(os.path.join(CONTRACTS, "MANIFEST.sha256"))))
        print("contracts synced @ %s" % full)
        print('commit it on its own: git add contracts && git commit -m "sync contracts @%s"' % full[:7])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def check(offline):
    problems = verify_manifest(CONTRACTS)
    fields = read_upstream() if os.path.isfile(os.path.join(CONTRACTS, "UPSTREAM")) else {}
    commit = fields.get("rhserver_commit", "")
    if len(commit) != 40:
        problems.append("UPSTREAM has no full rhserver_commit")
    if os.path.isfile(os.path.join(CONTRACTS, "MANIFEST.sha256")):
        if sha256_file(os.path.join(CONTRACTS, "MANIFEST.sha256")) != fields.get("manifest_sha256"):
            problems.append("MANIFEST.sha256 does not match manifest_sha256 in UPSTREAM")
    if not offline and len(commit) == 40:
        tmp = tempfile.mkdtemp(prefix="rh-contracts-")
        try:
            fetch(commit, tmp)
            upstream = os.path.join(tmp, "contracts")
            ours, theirs = list_files(CONTRACTS) + ["MANIFEST.sha256"], list_files(upstream) + ["MANIFEST.sha256"]
            if ours != theirs:
                problems.append("file list differs from RHServer @ %s" % commit[:7])
            for path in sorted(set(ours) & set(theirs)):
                if sha256_file(os.path.join(CONTRACTS, path)) != sha256_file(os.path.join(upstream, path)):
                    problems.append("differs from RHServer @ %s: %s" % (commit[:7], path))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        newer = tempfile.mkdtemp(prefix="rh-contracts-main-")
        try:
            main = fetch("main", newer)
            main_manifest = os.path.join(newer, "contracts", "MANIFEST.sha256")
            if main != commit and os.path.isfile(main_manifest) and \
                    sha256_file(main_manifest) != fields.get("manifest_sha256"):
                print("note: RHServer main (%s) has newer contracts; sync deliberately when ready" % main[:7])
        except subprocess.CalledProcessError:
            print("note: could not fetch RHServer main to look for newer contracts")
        finally:
            shutil.rmtree(newer, ignore_errors=True)
    if problems:
        sys.exit("contracts/ check failed:\n  " + "\n  ".join(problems))
    print("contracts/ OK @ %s" % commit[:7])


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "sync":
        sync(args[1])
    elif args[:1] == ["check"] and args[1:] in ([], ["--offline"]):
        check(offline=args[1:] == ["--offline"])
    else:
        sys.exit(__doc__)

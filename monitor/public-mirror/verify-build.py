#!/usr/bin/env python3
"""verify-build.py — post-scrub integrity check for the public-mirror build.

    verify-build.py <binaries.tsv>

Run by build.sh from the work-tree root AFTER the scrub and the exclude drop,
BEFORE the path renames, while the INDEX still holds the pre-scrub source and
the WORKING TREE holds the scrubbed output. It compares the two, file by file:

  * BINARY files (git's own classification, `git ls-files --eol` = i/-text)
    must be BYTE-IDENTICAL to their source blob. The scrub is a text
    substitution; applied to compressed image data it matched a short token
    twice inside a JPEG's entropy-coded segment and shipped a corrupt image
    (your-org/nexus-code#1812). build.sh no longer scrubs binaries; this is
    the independent check that none was rewritten anyway.
  * Every binary must also be REVIEWED: listed in <binaries.tsv> with the
    blob sha it has today. The scrub cannot screen a binary, and the leak gate
    can only grep its bytes, so a new or changed binary is a human decision
    (ship verbatim, drop with an `exclude`, or replace it in source), never a
    silent pass. The file names only public paths and object ids.
  * Scrubbed TEXT files must still PARSE wherever their source parsed: shell
    (`bash -n`, or `zsh -n` for a zsh shebang), Python (`compile`), JSON and
    YAML. A file whose SOURCE already fails to parse here (a deliberate
    fixture, or syntax newer than this host's interpreter) is not a
    regression and is not reported.

Exit codes: 0 clean; 10 parse regression; 11 binary rewritten or unreviewed;
2 usage / cannot read the index. Output names paths and check kinds only,
never file content.
"""
import json
import os
import subprocess
import sys
import tempfile

try:
    import yaml  # PyYAML; absent -> YAML is reported UNCHECKED, never "clean"
except Exception:  # pragma: no cover - host dependent
    yaml = None


def git(*args):
    return subprocess.run(("git",) + args, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=True).stdout


def index_entries():
    """{path: (mode, sha)} for every stage-0 index entry."""
    out = {}
    for rec in git("ls-files", "-s", "-z").split(b"\0"):
        if not rec:
            continue
        meta, path = rec.split(b"\t", 1)
        mode, sha, _stage = meta.split(b" ")
        out[path.decode("utf-8", "surrogateescape")] = (mode.decode(), sha.decode())
    return out


def binary_paths():
    out = set()
    for rec in git("ls-files", "--eol", "-z").split(b"\0"):
        if not rec or b"\t" not in rec:
            continue
        meta, path = rec.split(b"\t", 1)
        if meta.split()[0] == b"i/-text":
            out.add(path.decode("utf-8", "surrogateescape"))
    return out


def blob(sha):
    return git("cat-file", "blob", sha)


def shell_of(path, data):
    if path.endswith((".sh", ".bash")):
        first = data.split(b"\n", 1)[0]
        return "zsh" if b"zsh" in first else "bash"
    if data.startswith(b"#!"):
        first = data.split(b"\n", 1)[0]
        if b"zsh" in first:
            return "zsh"
        if b"bash" in first or first.rstrip().endswith((b"/sh", b" sh")):
            return "bash"
    return None


def parses(kind, data, path):
    """True / False, or None when this host cannot check the kind."""
    if kind in ("bash", "zsh"):
        with tempfile.NamedTemporaryFile(suffix=".sh") as tf:
            tf.write(data)
            tf.flush()
            try:
                r = subprocess.run([kind, "-n", tf.name], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=30)
            except (OSError, subprocess.TimeoutExpired):
                return None
            return r.returncode == 0
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return False
    if kind == "python":
        try:
            compile(text, path, "exec")
            return True
        except (SyntaxError, ValueError):
            return False
    if kind == "json":
        try:
            json.loads(text)
            return True
        except ValueError:
            return False
    if kind == "yaml":
        if yaml is None:
            return None
        try:
            list(yaml.safe_load_all(text))
            return True
        except yaml.YAMLError:
            return False
    return None


def kind_of(path, data):
    sh = shell_of(path, data)
    if sh:
        return sh
    if path.endswith(".py"):
        return "python"
    if path.endswith(".json"):
        return "json"
    if path.endswith((".yml", ".yaml")):
        return "yaml"
    if data.startswith(b"#!") and b"python" in data.split(b"\n", 1)[0]:
        return "python"
    return None


def main():
    if len(sys.argv) != 2:
        print("usage: verify-build.py <binaries.tsv>", file=sys.stderr)
        return 2
    allow = {}
    # An ABSENT list means "nothing reviewed", never "skip the check": a tree
    # with no binaries passes, and any binary fails closed as UNREVIEWED. (The
    # toolkit's fixture suites copy build.sh without a list; the real build
    # always has one.)
    try:
        if not os.path.exists(sys.argv[1]):
            raise FileNotFoundError
        with open(sys.argv[1], encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("#") or not line.strip():
                    continue
                f = line.rstrip("\n").split("\t")
                if len(f) >= 3 and f[0] == "binary":
                    allow[f[1]] = f[2]
    except FileNotFoundError:
        allow = {}
    except OSError as e:
        print("verify-build: cannot read binaries list %s: %s" % (sys.argv[1], e), file=sys.stderr)
        return 2
    try:
        idx = index_entries()
        bins = binary_paths()
    except subprocess.CalledProcessError as e:
        print("verify-build: git failed: %s" % e, file=sys.stderr)
        return 2

    bin_bad, parse_bad, unchecked = [], [], {}
    n_bin = n_checked = 0
    for path, (mode, sha) in sorted(idx.items()):
        if mode not in ("100644", "100755") or not os.path.isfile(path) or os.path.islink(path):
            continue
        with open(path, "rb") as fh:
            now = fh.read()
        if path in bins:
            n_bin += 1
            cur = git("hash-object", "--", path).decode().strip()
            if cur != sha:
                bin_bad.append("REWRITTEN   %s (source blob %s, output %s)" % (path, sha[:12], cur[:12]))
            want = allow.get(path)
            if want is None:
                bin_bad.append("UNREVIEWED  %s (blob %s) — add `binary<TAB>%s<TAB>%s` to %s after "
                               "reviewing it, or exclude it" % (path, sha[:12], path, sha, sys.argv[1]))
            elif want != sha:
                bin_bad.append("CHANGED     %s (reviewed %s, now %s) — re-review" % (path, want[:12], sha[:12]))
            continue
        src = blob(sha)
        if src == now:
            continue  # the scrub did not touch it: nothing it could have broken
        kind = kind_of(path, src)
        if kind is None:
            continue
        before = parses(kind, src, path)
        if before is not True:
            if before is None:
                unchecked[kind] = unchecked.get(kind, 0) + 1
            continue
        n_checked += 1
        after = parses(kind, now, path)
        if after is None:
            unchecked[kind] = unchecked.get(kind, 0) + 1
        elif not after:
            parse_bad.append("%-6s %s" % (kind, path))

    for p in sorted(allow):
        if p not in bins:
            print("verify-build: note: binaries list names %s, which is not a binary in this tree" % p,
                  file=sys.stderr)
    for k, n in sorted(unchecked.items()):
        print("verify-build: UNCHECKED %d scrubbed %s file(s) — this host cannot parse that kind" % (n, k),
              file=sys.stderr)
    for line in bin_bad:
        print("verify-build: BINARY " + line, file=sys.stderr)
    for line in parse_bad:
        print("verify-build: PARSE REGRESSION (source parsed, scrubbed output does not): " + line,
              file=sys.stderr)
    print("verify-build: %d binary file(s) byte-checked, %d scrubbed text file(s) parse-checked; "
          "%d binary problem(s), %d parse regression(s)" % (n_bin, n_checked, len(bin_bad), len(parse_bad)),
          file=sys.stderr)
    if bin_bad:
        return 11
    if parse_bad:
        return 10
    return 0


if __name__ == "__main__":
    sys.exit(main())

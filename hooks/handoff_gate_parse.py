#!/usr/bin/env python3
"""handoff_gate_parse.py: the parser behind handoff-gate.sh.

Reads the Bash command from $GATE_CMD (and the hook input's cwd from $GATE_CWD) and
finds every hand-off in it: a PATCH of /api/issues/<id> whose own body sets status
"in_review", or a Paperclip CLI `issue update <id> --status in_review`. For each it prints

  HANDOFF<TAB><id><TAB><sha>

<sha> is the commit the hand-off comment names: its `HEAD: <sha>` line, else the head of
its `Range: <base>..<head>` line; empty when the comment names neither.

Nothing is printed for anything else. A call that carries a review decision
(executionDecision in its JSON body or httpie items, or --execution-decision on the CLI)
is a reviewer's verdict, not a hand-off, and is never printed. This gate fails open:
an unparsable command or an unreadable body file prints nothing (the completion gate
owns the fail-closed checks).

The curl / httpie / wget parsing is shared with completion_gate_parse.py.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import completion_gate_parse as cg  # noqa: E402

REVIEW_RE = re.compile(r'\\?"status\\?"\s*:\s*\\?"in_review\\?"')
FORM_REVIEW_RE = re.compile(r"(?:^|&)status=in_review(?:&|$)")
DECISION_RE = re.compile(r'\\?"executionDecision\\?"\s*:')
CLI_BOOL = {"--json", "--help", "-h"}
HEAD_RE = re.compile(r"HEAD:\s*`?([0-9a-fA-F]{7,40})(?![0-9a-zA-Z])")
RANGE_RE = re.compile(r"Range:\s*`?[0-9a-fA-F]{7,40}\.\.([0-9a-fA-F]{7,40})(?![0-9a-zA-Z])")


def named_sha(texts):
    """The commit a hand-off comment names: `HEAD: <sha>`, else the head of `Range:`."""
    text = "\n".join(t for t in texts if isinstance(t, str))
    m = HEAD_RE.search(text) or RANGE_RE.search(text)
    return m.group(1).lower() if m else ""


def out(issue, sha=""):
    sys.stdout.write("HANDOFF\t%s\t%s\n" % (issue.replace("\n", " ").replace("\t", " "), sha))


def body_is_handoff(bodies):
    if not bodies:
        return False
    if len(bodies) == 1:
        try:
            obj = json.loads(bodies[0])
        except ValueError:
            obj = None
        if isinstance(obj, dict):
            return obj.get("status") == "in_review" and "executionDecision" not in obj
    text = "&".join(bodies)
    if DECISION_RE.search(text) or "executionDecision=" in text:
        return False
    return bool(REVIEW_RE.search(text) or FORM_REVIEW_RE.search(text))


def items_are_handoff(items):
    status, decision = None, False
    for it in items:
        m = re.match(r"^([A-Za-z_][\w.]*)(:=|=)(.*)$", it)
        if not m:
            continue
        key, op, val = m.groups()
        if op == ":=":
            try:
                val = json.loads(val)
            except ValueError:
                pass
        if key == "executionDecision":
            decision = True
        elif key == "status":
            status = val
    return status == "in_review" and not decision


def cli_handoffs(toks):
    """`<cli> issue update <id> --status in_review` (the Paperclip CLI)."""
    found = []
    for i in range(len(toks) - 1):
        if toks[i] != "issue" or toks[i + 1] != "update":
            continue
        args = []
        j = i + 2
        while j < len(toks) and not cg.is_sep(toks[j]):
            args.append(toks[j])
            j += 1
        issue = status = None
        decision = False
        k = 0
        while k < len(args):
            a = args[k]
            if a.startswith("-"):
                name, eq, val = a.partition("=")
                if not eq and name not in CLI_BOOL:
                    val = args[k + 1] if k + 1 < len(args) else ""
                    k += 1
                if name == "--status":
                    status = val
                elif name == "--execution-decision":
                    decision = True
            elif issue is None:
                issue = a
            k += 1
        if issue and status == "in_review" and not decision:
            found.append((issue, named_sha(args)))
    return found


def main():
    cmd = os.environ.get("GATE_CMD", "")
    try:
        toks = cg.tokenize(cmd)
    except ValueError:
        return
    for issue, sha in cli_handoffs(toks):
        out(issue, sha)
    for prog, args in cg.invocations(toks):
        try:
            if prog == "curl":
                method, bodies, urls = cg.curl_parse(args)
                verdict = lambda: body_is_handoff(bodies)
                texts = bodies
            elif prog == "wget":
                method, bodies, urls = cg.wget_parse(args)
                verdict = lambda: body_is_handoff(bodies)
                texts = bodies
            else:
                method, items, urls = cg.http_parse(args)
                verdict = lambda: items_are_handoff(items)
                texts = items
        except cg.Unreadable:
            continue
        if (method or "").upper() != "PATCH":
            continue
        issue = next((m.group(1) for m in (cg.ISSUE_RE.search(u) for u in urls) if m), None)
        if issue and verdict():
            out(issue, named_sha(texts))


if __name__ == "__main__":
    main()

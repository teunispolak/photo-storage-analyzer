#!/usr/bin/env python3
"""
Guards for the test script. Usage: lint_tests.py <script>. Exit 1 with the
offending line numbers, 0 when clean.

- No zsh-only commands inside `sh -c "..."`: sh does not have zsh's `print`;
  a check written as sh -c "... print ..." fails for the wrong reason.
- No check that reads last.out: check() writes the command's own output to
  last.out before the command runs, so the command reads its own empty
  output. Copy last.out to another file first.
"""

import re
import sys

SH_C = re.compile(r'sh -c "((?:[^"\\]|\\.)*)"')
ZSH_ONLY = re.compile(r'(?:^|[;&|({]|\$\()\s*print\b')
CHECK_READS_LAST = re.compile(r'^\s*check\s.*last\.out')


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    bad = []
    for no, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
        for m in SH_C.finditer(line):
            if ZSH_ONLY.search(m.group(1)):
                bad.append(f"line {no}: zsh 'print' inside sh -c; use printf or run without sh -c")
        if CHECK_READS_LAST.search(line):
            bad.append(f"line {no}: check reads last.out, which check overwrites; copy it first")
    for b in bad:
        print(b)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

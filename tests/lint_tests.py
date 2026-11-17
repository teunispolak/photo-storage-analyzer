#!/usr/bin/env python3
"""
Guard for the test script: no zsh-only commands inside `sh -c "..."`.

sh does not have zsh's `print`; a check written as sh -c "... print ..."
fails for the wrong reason. Usage: lint_tests.py <script>. Exit 1 with the
offending line numbers, 0 when clean.
"""

import re
import sys

SH_C = re.compile(r'sh -c "((?:[^"\\]|\\.)*)"')
ZSH_ONLY = re.compile(r'(?:^|[;&|({]|\$\()\s*print\b')


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    bad = []
    for no, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
        for m in SH_C.finditer(line):
            if ZSH_ONLY.search(m.group(1)):
                bad.append(no)
    for no in bad:
        print(f"line {no}: zsh 'print' inside sh -c; use printf or run without sh -c")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

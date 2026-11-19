#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Drops the statements of SELinux mapping files that reference types or attributes that no
# policy file declares, eg. the <type>_30_0 attributes of types that were not public yet when
# the target vendor policy was built. The vendor policy cannot use them anyway, while init
# fails to compile the split policy on boot because of them:
#   secilc: Failed to resolve expandtypeattribute statement at .../mapping/30.0.cil:873
#
# Usage: prune_mapping.py <policy.cil>... -- <mapping.cil>...
# Every policy file compiled on boot (and the mapping files themselves) declares names; the
# mapping files are rewritten in place. Prints one removed name per line.

import re
import sys

DECL = re.compile(r"^\((?:type|typeattribute|typealias)\s+([^\s()]+)\s*\)$")
EXPAND = re.compile(r"^\(expandtypeattribute\s+\(([^()]*)\)\s+(true|false)\s*\)$")
SET = re.compile(r"^\(typeattributeset\s+([^\s()]+)\s+\(([^()]*)\)\s*\)$")


def declared_names(paths):
    names = set()
    for path in paths:
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                for line in f:
                    m = DECL.match(line.strip())
                    if m:
                        names.add(m.group(1))
        except FileNotFoundError:
            pass
    return names


def prune(path, names):
    removed = set()
    out = []
    changed = False
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    for line in lines:
        s = line.strip()

        m = EXPAND.match(s)
        if m:
            attrs = m.group(1).split()
            keep = [a for a in attrs if a in names]
            if len(keep) != len(attrs):
                removed.update(a for a in attrs if a not in names)
                changed = True
                if keep:
                    out.append("(expandtypeattribute (%s) %s)\n" % (" ".join(keep), m.group(2)))
                continue

        m = SET.match(s)
        if m:
            attr, members = m.group(1), m.group(2).split()
            if attr not in names:
                removed.add(attr)
                changed = True
                continue
            keep = [t for t in members if t in names]
            if len(keep) != len(members):
                removed.update(t for t in members if t not in names)
                changed = True
                if keep:
                    out.append("(typeattributeset %s (%s))\n" % (attr, " ".join(keep)))
                continue

        out.append(line)

    if changed:
        with open(path, "w", encoding="utf-8") as f:
            f.writelines(out)
    return removed


def main():
    if "--" not in sys.argv[1:]:
        print("Usage: prune_mapping.py <policy.cil>... -- <mapping.cil>...", file=sys.stderr)
        return 2
    sep = sys.argv.index("--")
    policies, mappings = sys.argv[1:sep], sys.argv[sep + 1:]

    names = declared_names(policies + mappings)
    removed = set()
    for path in mappings:
        try:
            removed |= prune(path, names)
        except FileNotFoundError:
            pass
    for name in sorted(removed):
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())

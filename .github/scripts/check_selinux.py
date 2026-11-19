#!/usr/bin/env python3
#
# Checks the SELinux files of a ROM work dir the same way they are loaded on boot.
# Any error reported here is a guaranteed bootloop (or a broken boot) on the device:
#  - init (property_info_serializer) aborts on any duplicate property_contexts entry
#  - servicemanager/hwservicemanager abort on conflicting service_contexts/hwservice_contexts
#  - init fails to compile the split policy (secilc) when a mapping file references a type
#    that the vendor plat_pub_versioned.cil does not declare
#
# Usage: check_selinux.py <work_dir>
#

import os
import re
import shutil
import subprocess
import sys
import tempfile

errors = []
warnings = []


def part_dirs(work):
    system = os.path.join(work, "system", "system")
    if not os.path.isdir(system):
        system = os.path.join(work, "system")

    def pick(name, fallback):
        d = os.path.join(work, name)
        return d if os.path.isdir(os.path.join(d, "etc")) else fallback

    return {
        "system": system,
        "system_ext": pick("system_ext", os.path.join(system, "system_ext")),
        "product": pick("product", os.path.join(system, "product")),
        "vendor": os.path.join(work, "vendor"),
        "odm": pick("odm", os.path.join(work, "vendor", "odm")),
    }


def read_lines(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if line and not line.startswith("#"):
                yield n, line


def rel(path, work):
    return os.path.relpath(path, work)


def check_property_contexts(dirs, work):
    # system/core/init/property_service.cpp CreateSerializedPropertyInfo() load order
    files = [
        os.path.join(dirs["system"], "etc/selinux/plat_property_contexts"),
        os.path.join(dirs["system_ext"], "etc/selinux/system_ext_property_contexts"),
        os.path.join(dirs["vendor"], "etc/selinux/vendor_property_contexts"),
        os.path.join(dirs["product"], "etc/selinux/product_property_contexts"),
        os.path.join(dirs["odm"], "etc/selinux/odm_property_contexts"),
    ]
    seen = {}
    for path in files:
        if not os.path.isfile(path):
            continue
        for n, line in read_lines(path):
            tok = line.split()
            if len(tok) < 2:
                continue
            name, ctx = tok[0], tok[1]
            op = tok[2] if len(tok) > 2 else ""
            if op not in ("", "prefix", "exact"):
                # Rejected by ParsePropertyInfoLine() (vendor API >= 30), not fatal
                warnings.append("%s:%d: invalid match operation, line ignored: %s" % (rel(path, work), n, line))
                continue
            if op == "exact":
                key = (name, "exact")
            elif name.endswith("."):
                key = (name, "dot")
            else:
                key = (name, "prefix")
            where = "%s:%d (%s)" % (rel(path, work), n, ctx)
            if key in seen:
                # TrieBuilder::AddToTrie() fails on every duplicate, even with the same context
                errors.append("property_contexts: duplicate %s entry \"%s\": %s and %s"
                              % (key[1] if key[1] != "dot" else "prefix", name, seen[key], where))
            else:
                seen[key] = where


def check_service_contexts(dirs, work, kind):
    # external/selinux/libselinux/src/label_backends_android.c nodups_specs(): only entries
    # with different contexts are fatal, identical ones are just warned about
    prefix ={"service": "service_contexts", "hwservice": "hwservice_contexts"}[kind]
    files = [
        os.path.join(dirs["system"], "etc/selinux/plat_" + prefix),
        os.path.join(dirs["system_ext"], "etc/selinux/system_ext_" + prefix),
        os.path.join(dirs["product"], "etc/selinux/product_" + prefix),
        os.path.join(dirs["vendor"], "etc/selinux/vendor_" + prefix),
        os.path.join(dirs["odm"], "etc/selinux/odm_" + prefix),
    ]
    seen = {}
    for path in files:
        if not os.path.isfile(path):
            continue
        for n, line in read_lines(path):
            tok = line.split()
            if len(tok) < 2:
                continue
            name, ctx = tok[0], tok[1]
            where = "%s:%d (%s)" % (rel(path, work), n, ctx)
            if name in seen:
                if seen[name][0] != ctx:
                    errors.append("%s: conflicting entries for \"%s\": %s and %s" % (prefix, name, seen[name][1], where))
            else:
                seen[name] = (ctx, where)


def check_split_policy(dirs, work):
    secilc = shutil.which("secilc")
    if not secilc:
        warnings.append("secilc not found, skipping the split policy compilation")
        return

    vers_file = os.path.join(dirs["vendor"], "etc/selinux/plat_sepolicy_vers.txt")
    with open(vers_file) as f:
        vers = f.readline().strip()

    # system/core/init/selinux.cpp CompileSplitPolicy() file list
    files = [
        os.path.join(dirs["system"], "etc/selinux/plat_sepolicy.cil"),
        os.path.join(dirs["system"], "etc/selinux/mapping/%s.cil" % vers),
        os.path.join(dirs["system"], "etc/selinux/mapping/%s.compat.cil" % vers),
        os.path.join(dirs["system_ext"], "etc/selinux/system_ext_sepolicy.cil"),
        os.path.join(dirs["system_ext"], "etc/selinux/mapping/%s.cil" % vers),
        os.path.join(dirs["product"], "etc/selinux/product_sepolicy.cil"),
        os.path.join(dirs["product"], "etc/selinux/mapping/%s.cil" % vers),
        os.path.join(dirs["vendor"], "etc/selinux/plat_pub_versioned.cil"),
        os.path.join(dirs["vendor"], "etc/selinux/vendor_sepolicy.cil"),
        os.path.join(dirs["odm"], "etc/selinux/odm_sepolicy.cil"),
    ]
    for required in files[0:2] + files[7:9]:
        if not os.path.isfile(required):
            errors.append("sepolicy: missing %s" % rel(required, work))
            return

    tmp = tempfile.mkdtemp()
    try:
        args = []
        for i, path in enumerate(files):
            if not os.path.isfile(path):
                continue
            # Older secilc releases (< 3.8) do not know the nlmsg extended permissions,
            # dropping those rules does not change the type/attribute resolution
            out = os.path.join(tmp, "%02d_%s" % (i, os.path.basename(path)))
            with open(path, encoding="utf-8", errors="replace") as src, open(out, "w") as dst:
                for line in src:
                    if "(nlmsg " not in line:
                        dst.write(line)
            args.append(out)
        cmd = [secilc, "-m", "-M", "true", "-G", "-N", "-c", "30",
               "-o", os.path.join(tmp, "policy"), "-f", os.devnull] + args

        def to_rel(text):
            for i, path in enumerate(files):
                text = text.replace(os.path.join(tmp, "%02d_%s" % (i, os.path.basename(path))), rel(path, work))
            return text

        # secilc stops at the first statement it cannot resolve: blank it in the temporary copy and
        # compile again, so that a single run lists every statement that breaks the boot
        failures = []
        first_output = None
        for _ in range(60):
            p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            if p.returncode == 0:
                break
            if first_output is None:
                first_output = p.stdout.strip()
            m = re.search(r"Failed to resolve (\S+) statement at (\S+):(\d+)", p.stdout)
            if not m or not os.path.isfile(m.group(2)):
                failures.append(to_rel(p.stdout.strip()))
                break
            path, lineno = m.group(2), int(m.group(3))
            with open(path, encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
            if not 0 < lineno <= len(lines) or not lines[lineno - 1].strip():
                failures.append(to_rel(p.stdout.strip()))
                break
            failures.append("%s:%d: %s" % (to_rel(path), lineno, lines[lineno - 1].strip()[:300]))
            lines[lineno - 1] = "\n"
            with open(path, "w", encoding="utf-8") as f:
                f.writelines(lines)

        if failures:
            errors.append("sepolicy: split policy (vendor %s) does not compile:\n%s\nUnresolved statements:\n  %s"
                          % (vers, to_rel(first_output or ""), "\n  ".join(failures)))
        else:
            print("- Split policy (vendor %s) compiles fine" % vers)
    finally:
        shutil.rmtree(tmp)


def main():
    if len(sys.argv) != 2:
        print("Usage: check_selinux.py <work_dir>", file=sys.stderr)
        return 2
    work = os.path.abspath(sys.argv[1])
    dirs = part_dirs(work)
    for k, v in dirs.items():
        print("- %s: %s%s" % (k, rel(v, work), "" if os.path.isdir(v) else " (missing)"))

    check_property_contexts(dirs, work)
    check_service_contexts(dirs, work, "service")
    check_service_contexts(dirs, work, "hwservice")
    check_split_policy(dirs, work)

    for w in warnings:
        print("WARNING: " + w)
    for e in errors:
        print("ERROR: " + e)
    if errors:
        print("%d SELinux error(s) found, the device will not boot" % len(errors))
        return 1
    print("No SELinux errors found")
    return 0


if __name__ == "__main__":
    sys.exit(main())

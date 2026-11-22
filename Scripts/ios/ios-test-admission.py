#!/usr/bin/env python3
"""Admit a simulator test only when build-for-testing produced a real xctest image.

An enabled .xctestrun with zero TestConfigurations, a disabled plan, or only
library products (.a, .swiftmodule, a framework without an xctest executable)
is not tests compiled. The report records compiled_test_images and never
counts those library products. Every failure, including a damaged plist,
writes a report with its reason.
"""
import argparse
import json
import os
import plistlib
import re
import sys


MACH_O = {
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf",
}
# Xcode's xctestrun path tokens, such as __TESTROOT__ and __PLATFORMS__.
PLACEHOLDER = re.compile(r"__[A-Z][A-Z0-9_]*__")


def fail(report_path, report):
    report["tests_compiled"] = False
    report["compiled_test_images"] = len(report.get("images") or [])
    write_report(report_path, report)
    print("ios test admission: " + report["reason"], file=sys.stderr)
    return 65


def write_report(path, report):
    os.makedirs(os.path.dirname(os.path.realpath(path)), exist_ok=True)
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as stream:
        json.dump(report, stream, indent=2, sort_keys=True)
        stream.write("\n")
    os.replace(temporary, path)


def inside(root, path):
    root = os.path.realpath(root)
    candidate = os.path.realpath(path)
    return candidate == root or candidate.startswith(root + os.sep)


def is_macho(path):
    if not os.path.isfile(path) or os.path.islink(path) or os.path.getsize(path) < 4:
        return False
    with open(path, "rb") as stream:
        return stream.read(4) in MACH_O


def enabled(node):
    return node.get("IsEnabled", True) is not False and node.get("Skipped", False) is not True


def dictionary(value):
    return value if isinstance(value, dict) else {}


def read_plist(path, what):
    """Load a dictionary plist. A damaged or non-dictionary file is a ValueError."""
    try:
        with open(path, "rb") as stream:
            value = plistlib.load(stream)
    except Exception as error:  # plistlib raises ExpatError, InvalidFileException, ValueError, ...
        raise ValueError("%s is not a readable plist: %s (%s: %s)"
                         % (what, os.path.basename(path), type(error).__name__, error)) from error
    if not isinstance(value, dict):
        raise ValueError("%s is not a dictionary plist: %s" % (what, os.path.basename(path)))
    return value


def resolve(raw, test_root, test_host, field):
    """Substitute the known tokens. Only the xctestrun's own text is checked
    for unresolved tokens, so an output root such as /tmp/a__b still resolves."""
    if not isinstance(raw, str) or not raw:
        return None
    known = {"__TESTROOT__": test_root}
    if test_host:
        known["__TESTHOST__"] = test_host
    unresolved = sorted(set(PLACEHOLDER.findall(raw)) - set(known))
    if unresolved:
        raise ValueError("%s has an unresolved xctestrun placeholder %s: %s"
                         % (field, ", ".join(unresolved), raw))
    for token, value in known.items():
        raw = raw.replace(token, value)
    return raw


def xctestruns(products):
    found = []
    for dirpath, dirnames, filenames in os.walk(products):
        dirnames[:] = [name for name in dirnames
                       if not name.endswith((".app", ".xctest", ".framework", ".appex", ".swiftmodule"))]
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            if name.endswith(".xctestrun") and os.path.isfile(path) and not os.path.islink(path):
                found.append(path)
    return found


def bundle_executable(bundle):
    info_path = os.path.join(bundle, "Info.plist")
    if not os.path.isfile(info_path) or os.path.islink(info_path):
        return None
    info = read_plist(info_path, "bundle Info.plist")
    name = info.get("CFBundleExecutable") or os.path.splitext(os.path.basename(bundle))[0]
    if not isinstance(name, str) or not name or "/" in name or name.startswith("."):
        return None
    return os.path.join(bundle, name)


def scheme_name(plist):
    container = dictionary(plist.get("ContainerInfo"))
    if not container.get("SchemeName"):
        container = dictionary(dictionary(plist.get("__xctestrun_metadata__")).get("ContainerInfo"))
    return container.get("SchemeName")


def plan_targets(plist):
    """Return enabled targets, or None when the plan is explicitly empty.

    Format 2 stores TestConfigurations. An empty array is the library-only
    product scheme. Format 1 stores each test target as a top-level dictionary.
    """
    if "TestConfigurations" in plist:
        configurations = plist.get("TestConfigurations")
        if not isinstance(configurations, list) or not configurations:
            return None
        found = []
        for configuration in configurations:
            if not isinstance(configuration, dict) or not enabled(configuration):
                continue
            targets = configuration.get("TestTargets")
            if not isinstance(targets, list):
                raise ValueError("enabled test configuration lacks TestTargets")
            found.extend(target for target in targets if isinstance(target, dict) and enabled(target))
        return found
    return [value for key, value in plist.items()
            if not key.startswith("__") and isinstance(value, dict) and "TestBundlePath" in value
            and enabled(value)]


def image_for_target(target, test_root, derived, require_app_host=False):
    raw_host = target.get("TestHostPath") or ""
    host = None
    if isinstance(raw_host, str) and raw_host.endswith(".app"):
        host = resolve(raw_host, test_root, None, "TestHostPath")
        if host is None or not inside(derived, host) or not os.path.isdir(host):
            raise ValueError("enabled test host app was not built: " + str(target.get("BlueprintName")))
        host_executable = bundle_executable(host)
        if host_executable is None or not inside(derived, host_executable) or not is_macho(host_executable):
            raise ValueError("enabled test host has no Mach-O image: " + os.path.basename(host))
    if require_app_host and (host is None or target.get("IsAppHostedTestBundle") is not True
                             or target.get("IsUITestBundle", False)):
        raise ValueError("preview suite requires an app-hosted unit-test bundle with a built Mach-O host")
    app = target.get("UITargetAppPath")
    if isinstance(app, str) and app.endswith(".app"):
        app_path = resolve(app, test_root, host, "UITargetAppPath")
        if app_path is None or not inside(derived, app_path) or not os.path.isdir(app_path):
            raise ValueError("UI target app was not built: " + str(target.get("BlueprintName")))
        app_executable = bundle_executable(app_path)
        if app_executable is None or not is_macho(app_executable):
            raise ValueError("UI target app has no Mach-O image: " + os.path.basename(app_path))
    bundle = resolve(target.get("TestBundlePath"), test_root, host, "TestBundlePath")
    if bundle is None or not bundle.endswith(".xctest") or not inside(derived, bundle):
        raise ValueError("enabled test bundle is missing or escapes DerivedData: " + str(target.get("BlueprintName")))
    if not os.path.isdir(bundle) or os.path.islink(bundle):
        raise ValueError("enabled test bundle is not a real .xctest directory: " + os.path.basename(bundle))
    executable = bundle_executable(bundle)
    if executable is None or not inside(derived, executable) or not is_macho(executable):
        raise ValueError("enabled test bundle has no Mach-O xctest image: " + os.path.basename(bundle))
    return {"bundle": os.path.basename(bundle), "executable": os.path.basename(executable),
            "bytes": os.path.getsize(executable), "target": target.get("BlueprintName"),
            "app_hosted": target.get("IsAppHostedTestBundle", False),
            "host_app": os.path.basename(host) if host else None}


def admit(derived_data, scheme, require_app_host=False):
    derived = os.path.realpath(derived_data)
    products = os.path.join(derived, "Build", "Products")
    report = {"scheme": scheme, "tests_compiled": False, "compiled_test_images": 0,
              "images": [], "library_products_ignored": []}
    if not os.path.isdir(products):
        report["reason"] = "build products directory is missing"
        return report
    ignored = report["library_products_ignored"]
    for dirpath, dirnames, filenames in os.walk(products):
        # A .swiftmodule directory is one product; the files inside it are
        # per-architecture slices such as arm64-apple-ios-simulator.swiftmodule.
        ignored.extend(name for name in dirnames if name.endswith(".swiftmodule"))
        dirnames[:] = [name for name in dirnames
                       if not name.endswith((".app", ".xctest", ".framework", ".appex", ".swiftmodule"))]
        ignored.extend(name for name in filenames if name.endswith((".a", ".swiftmodule")))
    ignored.sort()
    plans, unreadable = [], []
    for path in xctestruns(products):
        try:
            plist = read_plist(path, "xctestrun")
        except ValueError as error:
            # Its scheme is unknown, so it cannot decide another scheme's
            # admission; a damaged plan of this scheme still leaves none.
            unreadable.append({"xctestrun": os.path.basename(path), "reason": str(error)})
            continue
        if scheme_name(plist) == scheme:
            plans.append((path, plist))
    if unreadable:
        report["unreadable_xctestruns"] = unreadable
    if len(plans) != 1:
        report["reason"] = "expected one enabled %s xctestrun, found %d" % (scheme, len(plans))
        if unreadable:
            report["reason"] += " (%d unreadable xctestrun skipped)" % len(unreadable)
        return report
    path, plist = plans[0]
    report["xctestrun"] = os.path.basename(path)
    targets = plan_targets(plist)
    if targets is None:
        report["reason"] = "xctestrun TestConfigurations is empty; library-only build-for-testing is not tests compiled"
        return report
    images = [image_for_target(target, os.path.dirname(path), derived, require_app_host) for target in targets]
    if not images:
        report["reason"] = "no enabled Mach-O xctest image; library-only build-for-testing is not tests compiled"
        return report
    report.update({"tests_compiled": True, "compiled_test_images": len(images), "images": images,
                   "reason": None})
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--derived-data", required=True)
    parser.add_argument("--scheme", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--require-app-host", action="store_true")
    args = parser.parse_args()
    try:
        report = admit(args.derived_data, args.scheme, args.require_app_host)
    except (OSError, ValueError) as error:
        return fail(args.report, {"scheme": args.scheme, "images": [], "reason": str(error)})
    except Exception as error:
        # Still fail closed with a report rather than a bare traceback.
        return fail(args.report, {"scheme": args.scheme, "images": [],
                                  "reason": "admission error: %s: %s" % (type(error).__name__, error)})
    if not report["tests_compiled"]:
        return fail(args.report, report)
    write_report(args.report, report)
    print("ios test admission: compiled_test_images={compiled_test_images} scheme={scheme}".format(**report))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Sanity-check RHClient.xcodeproj without Xcode: the pbxproj parses as an OpenStep plist,
every object id it references exists, every synchronized folder exists, and the shared
scheme points at real targets. Catches hand-editing mistakes; Xcode remains the real check."""
import os
import re
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(ROOT, "RHClient.xcodeproj", "project.pbxproj")
SCHEME = os.path.join(ROOT, "RHClient.xcodeproj", "xcshareddata", "xcschemes", "RHClient.xcscheme")
TOKEN = re.compile(r'\s+|/\*.*?\*/|//[^\n]*|"(?:[^"\\]|\\.)*"|[{}();=,]|[^\s{}();=,"]+', re.S)


def tokens(text):
    for match in TOKEN.finditer(text):
        tok = match.group(0)
        if tok.isspace() or tok.startswith("/*") or tok.startswith("//"):
            continue
        yield tok


def parse(toks):
    tok = next(toks)
    if tok == "{":
        result = {}
        while True:
            key = next(toks)
            if key == "}":
                return result
            if next(toks) != "=":
                raise ValueError("expected = after %s" % key)
            result[key.strip('"')] = parse(toks)
            if next(toks) != ";":
                raise ValueError("expected ; after value of %s" % key)
    if tok == "(":
        items = []
        while True:
            tok = next(toks)
            if tok == ")":
                return items
            items.append(parse(iter([tok])) if tok not in "{(" else parse(_prepend(tok, toks)))
            sep = next(toks)
            if sep == ")":
                return items
            if sep != ",":
                raise ValueError("expected , in list")
    return tok.strip('"')


def _prepend(first, rest):
    yield first
    yield from rest


def main():
    errors = []
    project = parse(tokens(open(PBXPROJ, encoding="utf-8").read()))
    objects = project["objects"]
    ids = set(objects)

    def walk(value, where):
        if isinstance(value, dict):
            for key, item in value.items():
                walk(item, where + "." + key)
        elif isinstance(value, list):
            for item in value:
                walk(item, where)
        elif re.fullmatch(r"[0-9A-F]{24}", value) and value not in ids:
            errors.append("dangling reference %s at %s" % (value, where))

    walk(objects, "objects")
    if project["rootObject"] not in ids:
        errors.append("rootObject missing")
    targets = {}
    for oid, obj in objects.items():
        if obj.get("isa") == "PBXFileSystemSynchronizedRootGroup":
            if not os.path.isdir(os.path.join(ROOT, obj["path"])):
                errors.append("synchronized folder missing: " + obj["path"])
        if obj.get("isa") == "XCLocalSwiftPackageReference":
            if not os.path.isfile(os.path.join(ROOT, obj["relativePath"], "Package.swift")):
                errors.append("local package missing: " + obj["relativePath"])
        if obj.get("isa") == "PBXNativeTarget":
            targets[oid] = obj["name"]
    for ref in ET.parse(SCHEME).iter("BuildableReference"):
        oid, name = ref.get("BlueprintIdentifier"), ref.get("BlueprintName")
        if targets.get(oid) != name:
            errors.append("scheme references unknown target %s (%s)" % (name, oid))
    if errors:
        sys.exit("RHClient.xcodeproj check failed:\n  " + "\n  ".join(errors))
    print("RHClient.xcodeproj OK: %d objects, targets %s" % (len(objects), ", ".join(sorted(targets.values()))))


if __name__ == "__main__":
    main()

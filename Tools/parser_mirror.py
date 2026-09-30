#!/usr/bin/env python3
"""Mirror of AuroraCore's ControlParser / ControlStanza round-trip.

The claim under test is the one the dpkg status writer depends on: parsing a
control file and serialising it again yields a stanza that parses identically.
This is a transcription of Sources/AuroraCore/Index/ControlStanza.swift, run over
the real fixtures, so a logic error is caught before CI ever sees it.
"""
import sys

FIXTURES = "/var/minis/workspace/Aurora/Tests/AuroraCoreTests/Fixtures/packages"


def parse(text):
    stanzas = []
    fields = []
    index = {}
    for raw in text.split("\n"):
        line = raw.rstrip("\r")
        if line == "":
            if fields:
                stanzas.append((fields, index))
                fields, index = [], {}
            continue
        if line[0] in " \t":
            remainder = line[1:]
            name, value = fields[-1]
            fields[-1] = (name, value + "\n" + remainder)
            continue
        if ":" not in line:
            continue
        name, _, value = line.partition(":")
        if value.startswith(" "):
            value = value[1:]
        if name.lower() not in index:
            index[name.lower()] = len(fields)
        fields.append((name, value))
    if fields:
        stanzas.append((fields, index))
    return stanzas


def serialized(stanza):
    fields, _ = stanza
    is_description = any(name.lower() == "description" for name, _ in fields)
    out = []
    for name, value in fields:
        lines = value.split("\n")
        out.append("%s: %s" % (name, lines[0]))
        for line in lines[1:]:
            if line == "":
                out.append(" ." if is_description and name.lower() == "description" else " ")
            else:
                out.append(" " + line)
    return "\n".join(out) + "\n\n"


def canon(stanza):
    """Fields as the Swift value type would hold them (plus ordering)."""
    return [(name.lower(), value) for name, value in stanza[0]]


def main():
    failures = 0
    for name in ["status", "Packages", "Release"]:
        with open("%s/%s" % (FIXTURES, name)) as handle:
            text = handle.read()
        original = parse(text)
        rebuilt = "\n".join(serialized(s) for s in original)
        reparsed = parse(rebuilt)
        if len(original) != len(reparsed):
            print("FAIL %s: %d stanzas parsed, %d after round-trip" % (name, len(original), len(reparsed)))
            failures += 1
            continue
        for position, (before, after) in enumerate(zip(original, reparsed)):
            if canon(before) != canon(after):
                print("FAIL %s stanza %d (%s)" % (name, position, before[0][1][:40]))
                for left, right in zip(canon(before), canon(after)):
                    if left != right:
                        print("   before %r" % (left,))
                        print("   after  %r" % (right,))
                failures += 1
                break
        else:
            # A second round-trip must be byte-identical too, or the writer
            # rewrites the status file on every run.
            if rebuilt != "\n".join(serialized(s) for s in reparsed):
                print("FAIL %s: serialisation is not idempotent" % name)
                failures += 1
            else:
                print("ok   %-10s %3d stanzas, round-trip and idempotent" % (name, len(original)))

    # Continuation of the specific shapes the tests assert on.
    status = parse(open("%s/status" % FIXTURES).read())
    by_name = {s[0][0][1]: s for s in status}
    half = dict((k.lower(), v) for k, v in by_name["halfbroken"][0])
    assert half["conffiles"] == "\n /etc/halfbroken.conf deadbeef", repr(half["conffiles"])
    print("ok   conffile continuation preserved exactly: %r" % half["conffiles"])
    public = dict((k.lower(), v) for k, v in by_name["bash"][0])
    assert public["essential"] == "yes"
    assert public["status"] == "install ok installed"
    print("ok   status/essential fields parsed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

"""Mirror of AuroraCore's DebianVersion ordering, used to validate the algorithm
against real dpkg before the Swift transcription exists."""


def order(c):
    if c is None:
        return 0
    if 48 <= c <= 57:
        return 0
    if (97 <= c <= 122) or (65 <= c <= 90):
        return c
    if c == 126:  # ~
        return -1
    return c + 256


def isdigit(c):
    return c is not None and 48 <= c <= 57


def verrevcmp(a, b):
    i = j = 0
    while i < len(a) or j < len(b):
        first_diff = 0
        while (i < len(a) and not isdigit(a[i])) or (j < len(b) and not isdigit(b[j])):
            left = order(a[i] if i < len(a) else None)
            right = order(b[j] if j < len(b) else None)
            if left != right:
                return -1 if left < right else 1
            i += 1
            j += 1
        while i < len(a) and a[i] == 48:
            i += 1
        while j < len(b) and b[j] == 48:
            j += 1
        while i < len(a) and j < len(b) and isdigit(a[i]) and isdigit(b[j]):
            if first_diff == 0:
                first_diff = a[i] - b[j]
            i += 1
            j += 1
        if i < len(a) and isdigit(a[i]):
            return 1
        if j < len(b) and isdigit(b[j]):
            return -1
        if first_diff != 0:
            return -1 if first_diff < 0 else 1
    return 0


def parse(raw):
    epoch = 0
    has_epoch = False
    body = raw
    if ":" in body:
        head, _, tail = body.partition(":")
        if head and head.isdigit() and head.isascii():
            epoch = int(head)
            has_epoch = True
            body = tail
    has_revision = False
    revision = ""
    if "-" in body:
        body, _, revision = body.rpartition("-")
        has_revision = True
    return {
        "epoch": epoch,
        "upstream": body.encode(),
        "revision": revision.encode(),
        "has_epoch": has_epoch,
        "has_revision": has_revision,
    }


def compare(a, b):
    pa, pb = parse(a), parse(b)
    if pa["epoch"] != pb["epoch"]:
        return -1 if pa["epoch"] < pb["epoch"] else 1
    r = verrevcmp(pa["upstream"], pb["upstream"])
    if r != 0:
        return r
    return verrevcmp(pa["revision"], pb["revision"])

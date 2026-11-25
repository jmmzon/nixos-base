"""Look up phone numbers in the contacts KDE Connect syncs from a phone.

KDE Connect's contacts plugin keeps one vCard per contact under
$XDG_DATA_HOME/kpeoplevcard/kdeconnect-<device>/. `call-contacts QUERY...`
prints one line per (contact, number) whose name contains every word of the
query, ignoring case and accents: name, label and number, tab-separated.
With no query it prints every contact. A number stored twice for the same
contact (local and international form) is printed once.
"""

import os
import quopri
import sys
import unicodedata
from pathlib import Path

# Letters NFKD does not decompose into a base letter and a mark.
FOLD = str.maketrans({"ł": "l", "ø": "o", "æ": "ae", "œ": "oe", "ß": "ss", "đ": "d", "ı": "i"})
TYPES = ("CELL", "MOBILE", "HOME", "WORK", "MAIN", "PAGER", "FAX")


def fold(text):
    text = unicodedata.normalize("NFKD", text.casefold().translate(FOLD))
    return "".join(c for c in text if not unicodedata.combining(c))


def logical_lines(raw):
    """Unfold continuation lines (RFC 6350) and quoted-printable soft breaks."""
    out = []
    for line in raw.splitlines():
        if out and line[:1] in (" ", "\t"):
            out[-1] += line[1:]
        elif out and out[-1].endswith("=") and "QUOTED-PRINTABLE" in out[-1].split(":", 1)[0].upper():
            out[-1] = out[-1][:-1] + line
        else:
            out.append(line)
    return out


def parse_line(line):
    head, _, value = line.partition(":")
    name, *params = head.split(";")
    params = [p.upper() for p in params]
    if "ENCODING=QUOTED-PRINTABLE" in params:
        charset = next((p.split("=", 1)[1] for p in params if p.startswith("CHARSET=")), "UTF-8")
        value = quopri.decodestring(value.encode()).decode(charset, "replace")
    return name.upper(), params, value.strip()


def label(params):
    flat = ",".join(params).replace("TYPE=", "")
    for t in TYPES:
        if t in flat.split(","):
            return "mobile" if t in ("CELL", "MOBILE") else t.lower()
    return "other"


def digits(number):
    return "".join(c for c in number if c.isdigit())


def same_number(a, b):
    """+48 600 700 800 and 600700800 are one number: one ends with the other."""
    a, b = digits(a), digits(b)
    short, long_ = sorted((a, b), key=len)
    return len(short) >= 7 and long_.endswith(short)


def contacts(root):
    for path in sorted(root.glob("kdeconnect-*/*.vcf")):
        try:
            lines = logical_lines(path.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
        name, structured, numbers = "", "", []
        for line in lines:
            key, params, value = parse_line(line)
            if key == "FN":
                name = value
            elif key == "N":
                structured = " ".join(p for p in reversed(value.split(";")) if p)
            elif key == "TEL" and value:
                numbers.append((label(params), value))
        name = name or structured
        if name and numbers:
            yield name, numbers


def main():
    data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")
    words = fold(" ".join(sys.argv[1:])).split()
    seen = []  # (folded name, number) already printed, across devices
    rows = []
    for name, numbers in contacts(data / "kpeoplevcard"):
        folded = fold(name)
        if not all(w in folded for w in words):
            continue
        # Whole-word prefix matches ("an" → "Anna Nowak") sort first.
        parts = folded.split()
        prefix = all(any(p.startswith(w) for p in parts) for w in words)
        for kind, number in numbers:
            if any(n == folded and same_number(number, m) for n, m in seen):
                continue
            seen.append((folded, number))
            rows.append((not prefix, folded, name, kind, number))
    for row in sorted(rows):
        print("\t".join(row[2:]))


if __name__ == "__main__":
    main()

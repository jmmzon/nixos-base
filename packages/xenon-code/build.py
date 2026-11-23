"""Cut a static four-style family from Monaspace Xenon's variable font.

Usage: build.py VARIABLE_TTF OUT_DIR FAMILY

Each style is pinned at fixed wght/wdth/slnt values (STYLES). The ligature
stylistic sets ss01-ss10 are appended to `calt`, which also carries texture
healing and is on by default, so applications without font-feature settings
render the same ligatures. HarfBuzz applies calt, liga and ssXX in one stage
in lookup-index order, so merged lookups run exactly as with the sets
enabled. The name tables are rewritten so fontconfig sees one family with
Regular, Bold, Italic and Bold Italic. The family does not use the
"Monaspace" Reserved Font Names of the OFL, as a modified version must not.
"""

import os
import sys

from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

# name: (location, weight class, bold, italic)
STYLES = {
    "Regular": ({"wght": 394, "wdth": 104, "slnt": -4}, 400, False, False),
    "Bold": ({"wght": 700, "wdth": 104, "slnt": -4}, 700, True, False),
    "Italic": ({"wght": 394, "wdth": 104, "slnt": -11}, 400, False, True),
    "Bold Italic": ({"wght": 700, "wdth": 104, "slnt": -11}, 700, True, True),
}
FROZEN_SETS = [f"ss{i:02d}" for i in range(1, 11)]


def check_axes(font):
    axes = {a.axisTag: (a.minValue, a.maxValue) for a in font["fvar"].axes}
    for style, (location, *_rest) in STYLES.items():
        for tag, value in location.items():
            lo, hi = axes[tag]
            if not lo <= value <= hi:
                sys.exit(f"{style}: {tag}={value} outside {lo}..{hi}")


def freeze_sets(font):
    gsub = font["GSUB"].table
    records = gsub.FeatureList.FeatureRecord
    extra = set()
    for record in records:
        if record.FeatureTag in FROZEN_SETS:
            extra.update(record.Feature.LookupListIndex)
    calts = [r for r in records if r.FeatureTag == "calt"]
    if not extra or not calts:
        sys.exit("no stylistic sets or no calt feature to freeze them into")
    for record in calts:
        merged = sorted(set(record.Feature.LookupListIndex) | extra)
        record.Feature.LookupListIndex = merged
        record.Feature.LookupCount = len(merged)
    if getattr(gsub, "FeatureVariations", None) is not None:
        sys.exit("feature variations left after instancing")


def set_names(font, family, style, weight, bold, italic):
    name = font["name"]
    version = font["head"].fontRevision
    ps_family = family.replace(" ", "")
    ps_name = f"{ps_family}-{style.replace(' ', '')}"
    for name_id in (1, 2, 3, 4, 6, 16, 17, 21, 22, 25):
        name.removeNames(nameID=name_id)
    full = family if style == "Regular" else f"{family} {style}"
    for name_id, value in {
        1: family,
        2: style,
        3: f"{version:.3f};{ps_name}",
        4: full,
        5: f"Version {version:.3f}",
        6: ps_name,
        10: "A static instance of Monaspace Xenon (SIL OFL 1.1) "
        "with ligature sets ss01-ss10 enabled through calt.",
    }.items():
        name.setName(value, name_id, 3, 1, 0x409)
        name.setName(value, name_id, 1, 0, 0)

    os2 = font["OS/2"]
    os2.usWeightClass = weight
    os2.usWidthClass = 5
    selection = os2.fsSelection & ~0b1100001  # clear ITALIC, BOLD, REGULAR
    selection |= (1 << 5) if bold else 0
    selection |= (1 << 0) if italic else 0
    if not bold and not italic:
        selection |= 1 << 6
    os2.fsSelection = selection
    font["head"].macStyle = (1 if bold else 0) | (2 if italic else 0)
    if "STAT" in font:
        del font["STAT"]


def main():
    source, out_dir, family = sys.argv[1:4]
    os.makedirs(out_dir, exist_ok=True)
    check_axes(TTFont(source))
    for style, (location, weight, bold, italic) in STYLES.items():
        font = instancer.instantiateVariableFont(TTFont(source), location)
        freeze_sets(font)
        set_names(font, family, style, weight, bold, italic)
        path = os.path.join(out_dir, f"{family.replace(' ', '')}-{style.replace(' ', '')}.ttf")
        font.save(path)
        print(path)


main()

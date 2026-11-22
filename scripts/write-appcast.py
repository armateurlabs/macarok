#!/usr/bin/env python3
"""Writes the Sparkle appcast for one release: its version, signed DMG, and Markdown release notes."""

import argparse
import email.utils
import os
import re
import sys
from xml.sax.saxutils import escape, quoteattr

# Installation and license sections describe the download page, not an update.
OMITTED_SECTIONS = ("## Download and install", "## License")


def release_notes(path):
    if not path or not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as file:
        text = file.read()
    cut = min((text.find(section) for section in OMITTED_SECTIONS if section in text), default=len(text))
    notes = text[:cut].strip()
    # The notes travel inside CDATA, which cannot contain its own terminator.
    return notes.replace("]]>", "]]&gt;")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="Release version, such as 1.0.0 or 1.1.0-beta.1")
    parser.add_argument("--build", required=True, help="CFBundleVersion of the release, which Sparkle compares")
    parser.add_argument("--dmg", required=True)
    parser.add_argument("--signature", required=True, help="EdDSA signature printed by sign_update -p")
    parser.add_argument("--url", required=True, help="Download URL of the DMG release asset")
    parser.add_argument("--notes", help="Markdown release notes")
    parser.add_argument("--minimum-system", default="14.0")
    parser.add_argument("--output", required=True)
    arguments = parser.parse_args()

    if not re.fullmatch(r"[1-9][0-9]*", arguments.build):
        sys.exit("The build number must be a positive integer.")
    if not re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", arguments.signature):
        sys.exit("The EdDSA signature must be base64.")
    length = os.path.getsize(arguments.dmg)
    notes = release_notes(arguments.notes)
    description = f'      <description sparkle:format="markdown"><![CDATA[{notes}]]></description>\n' if notes else ""
    appcast = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
        "  <channel>\n"
        "    <title>Macarok</title>\n"
        "    <item>\n"
        f"      <title>{escape('Macarok ' + arguments.version)}</title>\n"
        f"      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>\n"
        f"      <sparkle:version>{escape(arguments.build)}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{escape(arguments.version)}</sparkle:shortVersionString>\n"
        f"      <sparkle:minimumSystemVersion>{escape(arguments.minimum_system)}</sparkle:minimumSystemVersion>\n"
        f"{description}"
        f"      <enclosure url={quoteattr(arguments.url)} length=\"{length}\" type=\"application/octet-stream\""
        f" sparkle:edSignature={quoteattr(arguments.signature)}/>\n"
        "    </item>\n"
        "  </channel>\n"
        "</rss>\n"
    )
    with open(arguments.output, "w", encoding="utf-8") as file:
        file.write(appcast)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Serve a loopback-only OpenSubsonic music server and podcast feed for Macarok testing."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import http.server
import json
import math
import mimetypes
from pathlib import Path
import re
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import wave
import xml.etree.ElementTree as ET
import zlib


REPOSITORY = Path(__file__).resolve().parents[1]
AUDIO_EXTENSIONS = {".mp3", ".flac", ".ogg", ".opus", ".m4a", ".aac", ".wav", ".aif", ".aiff", ".alac", ".wv", ".ape"}
USERNAME = "demo"
PASSWORD = "macarok"
API_KEY = "macarok-demo-key"


def identifier(prefix: str, value: str) -> str:
    return prefix + hashlib.sha256(value.encode()).hexdigest()[:24]


def content_type(path: Path) -> str:
    return {".flac": "audio/flac", ".ogg": "audio/ogg", ".opus": "audio/ogg", ".mp3": "audio/mpeg",
            ".m4a": "audio/mp4", ".wav": "audio/wav", ".aif": "audio/aiff", ".aiff": "audio/aiff"}.get(path.suffix.lower(), mimetypes.guess_type(path.name)[0] or "application/octet-stream")


def duration(path: Path) -> float:
    try:
        if path.suffix.lower() == ".wav":
            with wave.open(str(path)) as audio:
                return audio.getnframes() / audio.getframerate()
        if path.suffix.lower() == ".flac":
            with path.open("rb") as audio:
                header = audio.read(42)
            if header[:4] == b"fLaC" and len(header) >= 42:
                value = int.from_bytes(header[18:26], "big")
                sample_rate = value >> 44
                if sample_rate:
                    return (value & ((1 << 36) - 1)) / sample_rate
        if path.suffix.lower() in {".ogg", ".opus"}:
            sample_rate = 48_000 if path.suffix.lower() == ".opus" else 0
            preskip = 0
            granule = 0
            with path.open("rb") as audio:
                while True:
                    header = audio.read(27)
                    if len(header) != 27 or header[:4] != b"OggS":
                        break
                    segments = audio.read(header[26])
                    packet = audio.read(sum(segments))
                    position = int.from_bytes(header[6:14], "little")
                    if position != (1 << 64) - 1:
                        granule = max(granule, position)
                    if packet.startswith(b"OpusHead") and len(packet) >= 12:
                        preskip = int.from_bytes(packet[10:12], "little")
                    if packet.startswith(b"\x01vorbis") and len(packet) >= 16:
                        sample_rate = int.from_bytes(packet[12:16], "little")
            if sample_rate:
                return max(0, granule - preskip) / sample_rate
    except (OSError, wave.Error, ValueError):
        pass
    return 5.0  # The generated codec-check files contain five seconds of synthetic audio.


def fallback_artwork(seed: str) -> bytes:
    size = 160
    digest = hashlib.sha256(seed.encode()).digest()
    base = (35 + digest[0] % 110, 50 + digest[1] % 100, 65 + digest[2] % 110)
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            ring = 39 < math.hypot(x - 100, y - 62) < 47
            rows.extend(min(255, int(channel * (0.65 + (x + y) / 500) + (70 if ring else 0))) for channel in base)

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)

    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(bytes(rows))) + chunk(b"IEND", b"")


class DemoLibrary:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.tracks: dict[str, dict] = {}
        self.files: dict[str, Path] = {}
        self.albums: dict[str, dict] = {}
        self.artists: dict[str, dict] = {}
        self.artwork: dict[str, tuple[bytes, str]] = {}
        self.play_counts: dict[str, int] = {}
        self.lock = threading.Lock()
        for path in sorted(self.root.rglob("*")):
            if not path.is_file() or path.suffix.lower() not in AUDIO_EXTENSIONS or not path.resolve().is_relative_to(self.root):
                continue
            relative = path.relative_to(self.root)
            artist = relative.parts[-3] if len(relative.parts) >= 3 else "Macarok Demo"
            album_folder = relative.parent.name if len(relative.parts) >= 2 else "Demo Library"
            year_match = re.match(r"^((?:19|20)\d\d)\s*[-–]\s*(.+)$", album_folder)
            year = int(year_match.group(1)) if year_match else 2026
            album_name = year_match.group(2) if year_match else album_folder
            match = re.match(r"^(\d+)\s*[-. ]\s*(.*)$", path.stem)
            title = match.group(2) if match else path.stem
            number = int(match.group(1)) if match else 1
            artist_id = identifier("artist-", artist)
            album_id = identifier("album-", relative.parent.as_posix())
            track_id = identifier("track-", relative.as_posix())
            length = duration(path)
            track = {"id": track_id, "parent": album_id, "isDir": False, "title": title, "artist": artist,
                     "albumArtist": artist, "artistId": artist_id, "albumId": album_id, "album": album_name,
                     "year": year, "genre": "Test Audio" if artist == "Macarok Demo" else "Ambient",
                     "track": number, "discNumber": 1, "duration": round(length, 3), "suffix": path.suffix[1:].lower(),
                     "contentType": content_type(path), "size": path.stat().st_size,
                     "bitRate": round(path.stat().st_size * 8 / max(length, 1) / 1000), "path": relative.as_posix(),
                     "coverArt": album_id, "created": "2026-11-14T12:00:00Z"}
            self.tracks[track_id] = track
            self.files[track_id] = path
            album = self.albums.setdefault(album_id, {"id": album_id, "name": album_name, "artist": artist,
                "artistId": artist_id, "year": year, "coverArt": album_id, "songCount": 0, "duration": 0,
                "created": "2026-11-14T12:00:00Z", "song": []})
            album["song"].append(track)
            album["songCount"] += 1
            album["duration"] += length
            self.artists.setdefault(artist_id, {"id": artist_id, "name": artist, "albumCount": 0, "album": []})
        for album in self.albums.values():
            album["song"].sort(key=lambda track: (track["discNumber"], track["track"], track["title"]))
            self.artists[album["artistId"]]["album"].append(self.album_summary(album))
        for artist in self.artists.values():
            artist["album"].sort(key=lambda album: (album["year"], album["name"]))
            artist["albumCount"] = len(artist["album"])

    @staticmethod
    def album_summary(album: dict) -> dict:
        return {key: value for key, value in album.items() if key != "song"}

    def cover(self, item_id: str) -> tuple[bytes, str]:
        album_id = self.tracks.get(item_id, {}).get("albumId", item_id)
        if album_id not in self.albums:
            raise KeyError(item_id)
        with self.lock:
            if album_id not in self.artwork:
                first = self.albums[album_id]["song"][0]["id"]
                directory = self.files[first].parent
                image = next((path for path in directory.iterdir() if path.is_file() and path.resolve().is_relative_to(self.root)
                              and path.name.lower() in {"cover.png", "cover.jpg", "folder.jpg", "folder.png", "front.jpg"}), None)
                self.artwork[album_id] = (image.read_bytes(), content_type(image)) if image else (fallback_artwork(album_id), "image/png")
            return self.artwork[album_id]


class DemoHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MacarokDemo/0.1"

    @property
    def library(self) -> DemoLibrary:
        return self.server.library

    def log_message(self, *_args) -> None:
        # Authenticated URLs contain API tokens. Access logs are deliberately disabled.
        pass

    def do_HEAD(self) -> None:
        self.route(head=True)

    def do_GET(self) -> None:
        self.route()

    def do_POST(self) -> None:
        self.route()

    def route(self, head: bool = False) -> None:
        url = urllib.parse.urlsplit(self.path)
        parameters = urllib.parse.parse_qs(url.query, keep_blank_values=True)
        if self.command == "POST":
            size = min(65536, max(0, int(self.headers.get("Content-Length", "0"))))
            parameters.update(urllib.parse.parse_qs(self.rfile.read(size).decode("utf-8"), keep_blank_values=True))
        values = {key: value[-1] for key, value in parameters.items()}
        try:
            if url.path == "/health":
                self.send_bytes(json.dumps({"status": "ok", "tracks": len(self.library.tracks), "albums": len(self.library.albums)}).encode(), "application/json", head=head)
            elif url.path in {"/podcast/feed.xml", "/podcast.rss"}:
                self.send_bytes(self.feed(), "application/rss+xml; charset=utf-8", head=head)
            elif url.path.startswith("/media/"):
                track_id = url.path.rsplit("/", 1)[-1].split(".", 1)[0]
                self.stream(track_id, head=head)
            elif url.path.startswith("/cover/"):
                cover_id = url.path.rsplit("/", 1)[-1].split(".", 1)[0]
                data, mime = self.library.cover(cover_id)
                self.send_bytes(data, mime, head=head)
            elif url.path.startswith("/rest/"):
                if not self.authenticated(values):
                    self.envelope({"error": {"code": 40, "message": "Use the demo credentials shown in the server documentation."}}, failed=True, head=head)
                    return
                endpoint = url.path.rsplit("/", 1)[-1].removesuffix(".view")
                if endpoint in {"stream", "download"}:
                    self.stream(values.get("id", ""), head=head)
                elif endpoint == "getCoverArt":
                    data, mime = self.library.cover(values.get("id", ""))
                    self.send_bytes(data, mime, head=head)
                else:
                    self.envelope(self.api(endpoint, values), head=head)
            else:
                self.send_bytes(b"Macarok loopback demo server\n", "text/plain", status=404, head=head)
        except KeyError:
            self.envelope({"error": {"code": 70, "message": "The requested demo item was not found."}}, failed=True, head=head)
        except (ValueError, TypeError):
            self.envelope({"error": {"code": 10, "message": "Invalid request parameters."}}, failed=True, head=head)
        except (BrokenPipeError, ConnectionResetError):
            pass

    @staticmethod
    def authenticated(values: dict[str, str]) -> bool:
        if "apiKey" in values:
            return hmac.compare_digest(values["apiKey"], API_KEY)
        if values.get("u") != USERNAME:
            return False
        if "t" in values and "s" in values:
            expected = hashlib.md5((PASSWORD + values["s"]).encode()).hexdigest()
            return hmac.compare_digest(values["t"], expected)
        password = values.get("p", "")
        if password.startswith("enc:"):
            try:
                password = bytes.fromhex(password[4:]).decode()
            except (ValueError, UnicodeDecodeError):
                return False
        return hmac.compare_digest(password, PASSWORD)

    def api(self, endpoint: str, values: dict[str, str]) -> dict:
        if endpoint in {"ping", "scrobble", "star", "unstar", "setRating"}:
            return {}
        if endpoint == "getOpenSubsonicExtensions":
            return {"openSubsonicExtensions": [{"name": "apiKeyAuthentication", "versions": [1]}, {"name": "formPost", "versions": [1]}]}
        if endpoint == "getAlbumList2":
            albums = sorted(self.library.albums.values(), key=lambda album: album["name"].casefold())
            offset, size = max(0, int(values.get("offset", "0"))), min(500, max(1, int(values.get("size", "500"))))
            return {"albumList2": {"album": [self.library.album_summary(album) for album in albums[offset:offset + size]]}}
        if endpoint == "getAlbum":
            return {"album": self.library.albums[values["id"]]}
        if endpoint == "getSong":
            return {"song": self.library.tracks[values["id"]]}
        if endpoint == "getArtists":
            indexes: dict[str, list] = {}
            for artist in sorted(self.library.artists.values(), key=lambda artist: artist["name"].casefold()):
                indexes.setdefault(artist["name"][0].upper(), []).append({key: value for key, value in artist.items() if key != "album"})
            return {"artists": {"ignoredArticles": "The A An", "index": [{"name": name, "artist": artists} for name, artists in indexes.items()]}}
        if endpoint == "getArtist":
            return {"artist": self.library.artists[values["id"]]}
        if endpoint == "getMusicFolders":
            return {"musicFolders": {"musicFolder": [{"id": "root", "name": "Macarok Demo Music"}]}}
        if endpoint == "getIndexes":
            return {"indexes": {"lastModified": 1_794_650_400_000, "index": self.api("getArtists", values)["artists"]["index"]}}
        if endpoint == "getMusicDirectory":
            item_id = values.get("id", "root")
            if item_id == "root":
                children = [{"id": artist["id"], "title": artist["name"], "isDir": True, "parent": "root"} for artist in self.library.artists.values()]
                return {"directory": {"id": "root", "name": "Music", "child": children}}
            if item_id in self.library.artists:
                artist = self.library.artists[item_id]
                return {"directory": {"id": item_id, "name": artist["name"], "parent": "root", "child": [{"id": album["id"], "title": album["name"], "isDir": True, "parent": item_id, "coverArt": album["id"]} for album in artist["album"]]}}
            album = self.library.albums[item_id]
            return {"directory": {"id": item_id, "name": album["name"], "parent": album["artistId"], "child": album["song"]}}
        if endpoint == "search3":
            query = values.get("query", "").casefold()
            songs = [track for track in self.library.tracks.values() if query in " ".join([track["title"], track["artist"], track["album"]]).casefold()]
            offset, size = max(0, int(values.get("songOffset", "0"))), max(0, int(values.get("songCount", "20")))
            return {"searchResult3": {"song": songs[offset:offset + size]}}
        if endpoint == "getLyricsBySongId":
            track = self.library.tracks[values["id"]]
            return {"lyricsList": {"structuredLyrics": [{"displayArtist": track["artist"], "displayTitle": track["title"], "lang": "eng", "synced": False, "line": [{"value": "Instrumental demo audio. No lyrics are attached."}]}]}}
        if endpoint == "getLyrics":
            return {"lyrics": {"artist": values.get("artist", ""), "title": values.get("title", ""), "value": "Instrumental demo audio."}}
        if endpoint == "getScanStatus":
            return {"scanStatus": {"scanning": False, "count": len(self.library.tracks)}}
        raise KeyError(endpoint)

    def envelope(self, value: dict, failed: bool = False, head: bool = False) -> None:
        response = {"status": "failed" if failed else "ok", "version": "1.16.1", "type": "MacarokDemo", "serverVersion": "0.1.0", "openSubsonic": True, **value}
        self.send_bytes(json.dumps({"subsonic-response": response}, ensure_ascii=False).encode(), "application/json; charset=utf-8", head=head)

    def send_bytes(self, data: bytes, mime: str, status: int = 200, head: bool = False) -> None:
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if not head:
            self.wfile.write(data)

    def stream(self, track_id: str, head: bool = False) -> None:
        path = self.library.files[track_id].resolve()
        if not path.is_relative_to(self.library.root):
            raise KeyError(track_id)
        size = path.stat().st_size
        start, end = 0, size - 1
        partial = False
        value = self.headers.get("Range")
        if value:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", value.strip())
            if not match or (not match[1] and not match[2]):
                self.invalid_range(size)
                return
            if match[1]:
                start = int(match[1])
                if match[2]:
                    end = min(end, int(match[2]))
            else:
                start = max(0, size - int(match[2]))
            if start >= size or end < start:
                self.invalid_range(size)
                return
            partial = True
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", content_type(path))
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head:
            return
        with path.open("rb") as audio:
            audio.seek(start)
            remaining = end - start + 1
            while remaining:
                data = audio.read(min(self.server.chunk_size, remaining))
                if not data:
                    break
                self.wfile.write(data)
                self.wfile.flush()
                remaining -= len(data)
                if self.server.chunk_delay:
                    time.sleep(self.server.chunk_delay)

    def invalid_range(self, total: int) -> None:
        self.send_response(416)
        self.send_header("Content-Range", f"bytes */{total}")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def feed(self) -> bytes:
        ET.register_namespace("itunes", "http://www.itunes.com/dtds/podcast-1.0.dtd")
        namespace = "{http://www.itunes.com/dtds/podcast-1.0.dtd}"
        base = f"http://127.0.0.1:{self.server.server_port}"
        rss = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(rss, "channel")
        ET.SubElement(channel, "title").text = "Macarok Demo Podcast"
        ET.SubElement(channel, "description").text = "Synthetic audio served locally for offline testing."
        ET.SubElement(channel, "link").text = base + "/podcast/feed.xml"
        ET.SubElement(channel, namespace + "author").text = "Macarok Demo"
        for index, track in enumerate(list(self.library.tracks.values())[:4]):
            if index == 0:
                ET.SubElement(channel, namespace + "image", {"href": base + "/cover/" + track["albumId"] + ".png"})
            item = ET.SubElement(channel, "item")
            ET.SubElement(item, "title").text = track["title"]
            ET.SubElement(item, "guid", {"isPermaLink": "false"}).text = track["id"]
            ET.SubElement(item, "description").text = "Synthetic test episode from " + track["album"] + "."
            ET.SubElement(item, "pubDate").text = f"{['Sat, 14', 'Fri, 13', 'Thu, 12', 'Wed, 11'][index]} Nov 2026 12:00:00 +0000"
            ET.SubElement(item, "enclosure", {"url": base + "/media/" + track["id"] + "." + track["suffix"], "type": track["contentType"], "length": str(track["size"])})
            ET.SubElement(item, namespace + "duration").text = str(round(track["duration"]))
            ET.SubElement(item, namespace + "episode").text = str(4 - index)
        return ET.tostring(rss, encoding="utf-8", xml_declaration=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library", nargs="?", type=Path, help="Explicitly select the only folder the server may serve.")
    parser.add_argument("--port", type=int, default=4533, help="Loopback port; use 0 to choose a free port.")
    parser.add_argument("--chunk-delay", type=float, default=0, help="Delay each audio chunk, in seconds, to exercise buffering.")
    parser.add_argument("--chunk-size", type=int, default=65536, help="Audio chunk size in bytes.")
    parser.add_argument("--ready-file", type=Path, help="Write connection details as JSON for an integration-test harness.")
    args = parser.parse_args()
    if not 0 <= args.port <= 65535 or args.chunk_delay < 0 or not math.isfinite(args.chunk_delay):
        parser.error("Use a valid port and a nonnegative finite chunk delay.")
    root = args.library.expanduser().resolve() if args.library else REPOSITORY / ".build/demo-library"
    if args.library is None and not (root / ".macarok-demo.json").is_file():
        if root.exists() and any(root.iterdir()):
            parser.error("The default folder was not generated by Macarok. Pass its path explicitly to serve it.")
        subprocess.run([sys.executable, str(REPOSITORY / "scripts/create-demo-library.py"), str(root), "--no-codecs"], check=True, stdout=subprocess.DEVNULL)
    if not root.is_dir():
        parser.error("The selected library folder does not exist.")
    library = DemoLibrary(root)
    if not library.tracks:
        parser.error("No supported audio files were found in the selected folder.")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), DemoHandler)
    server.daemon_threads = True
    server.library = library
    server.chunk_size = min(1024 * 1024, max(1024, args.chunk_size))
    server.chunk_delay = args.chunk_delay
    base = f"http://127.0.0.1:{server.server_port}"
    details = {"url": base, "username": USERNAME, "password": PASSWORD, "apiKey": API_KEY,
               "podcast": base + "/podcast/feed.xml", "tracks": len(library.tracks), "albums": len(library.albums)}
    if args.ready_file:
        args.ready_file.parent.mkdir(parents=True, exist_ok=True)
        args.ready_file.write_text(json.dumps(details, indent=2) + "\n")
    print(json.dumps(details), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

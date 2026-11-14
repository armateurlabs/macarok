# Offline source integration demo

Macarok includes a Python standard-library server for reviewing real OpenSubsonic and podcast connections without an external account. It binds only to `127.0.0.1` and serves the generated demo collection by default.

## Start the server

From the repository root:

```sh
python3 scripts/create-demo-library.py .build/demo-library
python3 scripts/demo-server.py --port 4533
```

If the generated demo library is already present, run only the second command. If the default library does not exist, the server generates the standard-library WAV collection automatically. Optional codec samples from the library generator are also served when present.

The startup line contains JSON connection details. Access logs are disabled so authenticated request URLs and tokens are not printed.

## Connect Macarok

In **Add a Music Source → OpenSubsonic**, enter:

| Field | Value |
| --- | --- |
| Name | Macarok Demo Server |
| Server URL | `http://127.0.0.1:4533` |
| Username | `demo` |
| Password | `macarok` |

API-key authentication is also available with `macarok-demo-key` instead of the username and password. These are fixed test credentials for the loopback server.

Add a separate **Podcast** source using:

```text
http://127.0.0.1:4533/podcast/feed.xml
```

Verify that the local folder, OpenSubsonic server, and podcast each have their own library and search results. Add tracks from them to the active playlist and confirm native playback, seeking, source artwork, and podcast episodes.

The server exposes physical audio files. The local-folder source demonstrates CUE sheets as separate virtual tracks; the demo server itself does not transcode or split album images.

## Exercise buffering

```sh
python3 scripts/demo-server.py --port 4533 --chunk-delay 0.08 --chunk-size 65536
```

Each audio chunk is delayed to make progressive buffering visible. Adjust **Settings → Playback → Streaming buffer** and start a new streamed track. Playback should begin after priming the target buffer rather than waiting for the entire file to download.

## Integration-test controls

```sh
python3 scripts/demo-server.py .build/demo-library --port 0 --ready-file .build/demo-server.json
```

Port `0` chooses an available loopback port. The ready file records its URL, feed URL, fixed demo credentials, and collection counts. `/health` returns a small unauthenticated health response.

The implementation supports the APIs used by Macarok: ping, extension discovery, artist and album browsing, file-directory browsing, search, artwork, original streaming/downloads, and a synthetic lyrics response. Audio endpoints support `HEAD`, complete responses, and validated single byte ranges. HTTP form POST is supported alongside query requests.

Pass another folder explicitly to serve it. Paths outside that folder, including symlinks to other locations, are excluded. The server reads the chosen audio files without rewriting their tags. Stop it with **Control-C**.

For HTTPS and certificate-policy verification, run `swift test --filter CertificatePolicyTests`. Those tests generate short-lived certificates and exercise an actual loopback HTTPS server, including remembered per-source trust and progressive byte-range delivery.

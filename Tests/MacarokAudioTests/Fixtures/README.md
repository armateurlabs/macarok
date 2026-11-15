# Audio fixtures

`variable-bitrate-podcast.mp3` is synthetic test audio generated locally, with
alternating quiet and loud seeded noise. It is 128 seconds long and includes a
Xing seek table. It contains no third-party recording.

To regenerate it with FFmpeg and libmp3lame:

```sh
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i 'anoisesrc=duration=128:sample_rate=22050:amplitude=0.2:seed=77' \
  -af 'volume=if(lt(mod(t\,8)\,4)\,0.01\,1):eval=frame' \
  -ac 1 -c:a libmp3lame -q:a 7 -write_xing 1 \
  -metadata title='Synthetic variable-bitrate podcast' \
  -metadata artist='Macarok test fixture' \
  -y variable-bitrate-podcast.mp3
```

FFmpeg is only needed to regenerate this fixture; test execution uses the
committed MP3 and the pinned VLCKit runtime.

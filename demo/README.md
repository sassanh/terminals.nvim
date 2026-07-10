# Demo assets

Sanitized demo for README screencasts. Uses a fake project, a generic `demo$`
prompt, and scripted terminal content so nothing personal is shown.

The recording:

1. Types `echo "This is terminal 1"` and `echo "This is terminal 2"` live
2. Opens a `watch`-style terminal and a monitoring terminal
3. Cycles back through slots 1-4 to show each terminal keeps its own content

Regenerate:

```sh
./demo/capture.sh
```

Requires [VHS](https://github.com/charmbracelet/vhs) and ffmpeg.
# Demo recording tools

This directory contains maintainer tooling for reproducing the demo shown in
the project README. It is not used when the plugin is installed or at runtime.
Generated recordings and intermediate files belong under `demo/out*`, which is
ignored by Git.

The scripts split the recording workflow into three deterministic steps:

- `make-demo-repo.sh` creates a disposable Git repository with fixed history
  and working-tree changes.
- `launch-stage.sh` opens a clean Ghostty window with a named herdr session.
  It is macOS-specific.
- `choreography.sh` drives the visible Herdr/lazygit interactions and prints
  timestamped scene markers for post-processing.

## Prerequisites

- macOS and Ghostty for `launch-stage.sh`
- herdr with this plugin installed or linked, plus Python 3
- `bat` for the staged code view (the script falls back to `cat`)
- A screen recorder and post-processing workflow; the published media was
  produced with the
  [promo-gif](https://github.com/Crokily/colys-agent-lab/tree/main/skills/promo-gif)
  skill

## Prepare and run the stage

Use a disposable target directory; `make-demo-repo.sh` replaces it completely.

```sh
./demo/make-demo-repo.sh /tmp/herdr-lazygit-demo-repo
./demo/launch-stage.sh gifdemo
./demo/choreography.sh /tmp/herdr-lazygit-demo-repo gifdemo
```

Start screen capture before running `choreography.sh`. Its `[scene ...]` lines
can be redirected to a timing log and used to trim or caption the recording.
Set `FAST=1` for a structural dry run, or `SKIP_FOCUS=1` when validating the
sequence without switching the Herdr UI to the demo workspace.

The capture and encoding steps are deliberately not embedded here because they
depend on the recorder. Only final media referenced by the main README should
be copied into `docs/media/` and committed.

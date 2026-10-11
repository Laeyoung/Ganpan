# Ganpan demo

`index.html` is a **conceptual simulation** of Ganpan. It is a single HTML file with no dependencies, and it never talks to GitHub. A scripted scenario shows six issues moving through the `status:*` label state machine. The Triager, Coder, Reviewer and QA lanes pick up work by reading those labels, and a human steps in only when the agents ask for judgment.

Open it directly in a browser. A server is not required.

```bash
open demo/index.html              # macOS
```

| URL parameter | Effect |
|---|---|
| `?autoplay=1` | Skips the start button and answers human decisions automatically (used to record the videos) |
| `?lang=en` | English captions (Korean by default; the `EN` / `한국어` button also switches) |
| `?speed=2` | Playback speed (the `1×` button cycles 1 / 1.5 / 2 / 4) |

Keyboard: `Space` toggles play/pause.

## What the scenario covers

1. **Backlog**: a human opens issues, which all start at `status:triage`. `/ganpan:run-all` launches the four lanes.
2. **Triage**: orphan locks are reclaimed and issues are classified. An issue without acceptance criteria goes to `status:blocked` instead of being guessed at.
3. **Coding**: `claim.sh` locks an issue (one issue = one `issue-<n>` branch = one worktree), then a PR is opened with `Refs #n`.
4. **Review & merge**: agents never approve. With the default `reviewer.autoMerge: false`, the Reviewer requests a human merge. Once that is opted in, it merges CLEAN PRs itself.
5. **Human decision**: a product question becomes `status:needs-decision`, and only trusted answers resolve it. Out-of-scope work is split into a follow-up issue.
6. **QA fail → rework**: QA runs the merged result and sends the issue back with a repro. Only QA closes issues.
7. **Unblock**: a human answers the blocked issue, and the Triager re-queues it.

## Videos

- `ganpan-demo-ko.mp4`: Korean captions, 1920×1080, about 86 s
- `ganpan-demo-en.mp4`: English captions, 1920×1080, about 86 s

Both are recorded from `index.html?autoplay=1` with Playwright at a 1600×900 viewport, then upscaled to 1080p with ffmpeg. `record.cjs` does both steps. Playwright is not a repo dependency, so install it in a scratch directory first:

```bash
(cd "$(mktemp -d)" && npm i playwright && NODE_PATH="$PWD/node_modules" node /path/to/ganpan/demo/record.cjs)
```

Re-record the videos whenever the scenario in `index.html` changes.

# Wordhand repository safety

This project controls global keyboard input and can inject synthetic events into
every application in the current macOS login session.

On Aaron's shared development Mac:

- Never leave `wordhand run`, `.build/debug/wordhand run`,
  `.build/release/wordhand run`, or another interactive global-input path
  running unattended.
- Do not use `--skip-doctor` as a testing shortcut. It does not isolate global
  input.
- Test shortcut routing and insertion through injected fakes. `swift test`,
  builds, and offline model benchmarks are permitted because they do not install
  the event tap or post text.
- Set `WORDHAND_SAFE=1` when a command might resolve to the default `run`
  subcommand. Safe mode must exit before runtime setup.
- A deliberate real global-input development test must be attended, use both
  `--allow-global-input-test` and
  `--global-input-test-timeout-seconds` with a value from 1 through 30.
- Development and source builds use `com.valyou.wordhand.dev` and must never
  register a LaunchAgent, login item, or background item. Never pass
  `--launch-at-login` to a development installer. Only a deliberately built,
  Developer-ID-signed release with `com.valyou.wordhand` may expose native
  launch at login.
- Release updates must retain the same bundle identifier, installed path, and
  Developer ID signing identity. They must not unregister and re-register the
  login item during replacement; an update that re-prompts for Background
  Items or privacy access fails the shipping bar.
- The documented immediate kill path is `/usr/bin/pkill -x wordhand`. Confirm
  with `/usr/bin/pgrep -x wordhand`; no output means no process remains.
- Normal user-owned runs remain frictionless. Development runs stay short,
  deliberate, attended, and time-bounded.

The durable incident receipt and rationale live at
`docs/verification/2026-07-28-global-input-safety.md`.

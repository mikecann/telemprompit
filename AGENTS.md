# Agent guidance for telemprompit

Native macOS teleprompter built with SwiftUI and AppKit. All paths below are
relative to this repo's root.

## Key rules

- Use test-first development for non-trivial changes. Write or update the
  automated test first, then implement the change until the test passes. If
  there is no clean test seam, extract one first.
- When behaviour changes, update affected expectations and rerun the relevant
  tests. This includes UI copy, layout, persistence and startup behaviour.
- Test before committing. Run the automated tests and smoke-test the actual app
  when changing its behaviour. Check script exit codes.
- Keep launchers pointing into this clone. `install.sh` links only
  `telemprompit` into `~/.local/bin` or the supplied target directory. Re-run it
  after moving the repo.
- Keep generated apps and Swift build output out of Git.
- Preserve `com.mikerosoft.telemprompit` as the bundle and signing identifier.
  Existing settings and Accessibility grants use this identity.
- Keep documentation plain and conversational. Do not use em or en dashes.

## telemprompit specifics

SwiftUI/AppKit teleprompter for the Elgato Prompter. Paste notes, step
through them line by line, or auto-scroll.

### Dev workflow

```bash
swift test
bash restart.sh
```

- `open -g telemprompit://next` (and `previous`, `play`, `pause`, `paste`,
  `settings`) drives the running app without focusing it. Use it for smoke
  tests instead of synthesising clicks.
- Global hotkeys use Carbon `RegisterEventHotKey`. Synthetic `CGEvent`s do
  not trigger them, so verify them with a real key press or clicker.
- Display lookup and the DisplayLink switch come from
  [PrompterKit](https://github.com/mikecann/prompter-kit), a separate Swift
  package. When updating the dependency, run its tests in its own clone and
  rerun `swift test` here.
- The automated tests use fake screen geometry and isolated settings suites.
  They need no Elgato Prompter or Accessibility grant. The clipboard integration
  test needs access to the macOS pasteboard service. In headless or managed
  environments, set `TELEMPROMPIT_SKIP_PASTEBOARD_TESTS=1` to skip only that test,
  as CI does. Keep the full default suite enabled on a normal desktop.
  Real display switching still needs DisplayLink Manager, hardware and permission.

### Build and install

```bash
bash setup_mac.sh    # release app in ~/Applications/Telemprompit.app
bash install.sh      # symlink the CLI launcher into ~/.local/bin
```

`build-app.sh` stages and signs the app. Use `TELEMPROMPIT_APP_DIR` for an
isolated app bundle during verification and `TELEMPROMPIT_CODESIGN_IDENTITY=-`
for ad-hoc signing. `restart.sh` rebuilds in debug mode and launches the app.

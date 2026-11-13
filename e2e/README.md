# Fresh-Mac release check

Installs the published, notarized ScreenPost on a clean GitHub-hosted macOS runner and drives it like a new user.
It never connects X, never posts and never buys anything. It runs only on GitHub-hosted runners with no secrets.

## What it checks

1. `https://screenpost.app/download` and the latest `ScreenPost.zip` release asset of this repo are byte-identical (sha256).
2. The app passes `codesign --verify --deep --strict` and `spctl` reports it accepted and Notarized.
3. Installs to `/Applications` and prints version and build.
4. Grants permissions without a prompt by writing the TCC database (runner only): Screen Recording for the app,
   bound to its code-signing requirement so only the genuine app matches; Accessibility for the `spdrive` driver.
   The Screen Recording step of onboarding is first screenshotted without the grant.
5. Onboarding through every step to Done (Connect X: "Skip for now"; Set up AI: free uses), a capture by area drag,
   Edit, Save to Desktop (a non-trivial PNG must appear), a full-screen capture from the menu bar item, the capture
   card Save, and History showing the card actions.

Labels of 1.6.1 and 1.6.2 are both accepted (`a|b` alternates).

## Run it

Actions tab, "release-check", Run workflow. It also runs on every published release and weekly. Artifacts per runner:
`report.md` (each step pass/fail with its screenshot), step screenshots, `spdrive.log`, `release-check.log`,
`app-log.txt` (`log show` for the app), and accessibility tree dumps.

Do not run `release-check.sh` on a personal Mac: it edits TCC and `/Applications`.

## spdrive

`e2e/spdrive` is a dependency-free Swift CLI that presses controls through the Accessibility API without moving the
mouse (except `drag`). Run `spdrive --help` for the command list. Read-only local use is fine:

    swift build -c release --package-path e2e/spdrive
    e2e/spdrive/.build/release/spdrive dump --window ScreenPost

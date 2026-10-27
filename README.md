# Navi

**A tutor that draws on your screen.** Ask about whatever's in front of you and Navi
answers on top of it: it points, rings and sketches, a sentence at a time, and walks
you through things step by step so you learn to do them yourself, rather than doing
them for you. It runs on your own Claude. There's no Navi account and no servers of ours.

Free and open source (Apache 2.0). **This is a beta**: expect rough edges, and please
[report anything odd](https://github.com/remodivito/navi/issues/new).

## What you need

- A Mac with **macOS 15** or later. (Windows is on its way.)
- A **Claude plan (Pro or Max)**, or an Anthropic API key if you'd rather pay as you go.
  Navi uses Claude to see and answer. The free Claude plan can't be used this way.

## Install

1. Download `Navi-<version>.dmg` from the
   [latest release](https://github.com/remodivito/navi/releases/latest) and open it.
2. Drag **Navi** onto **Applications**, then open it from Applications.
   (If you open it straight from the disk image, Navi offers to move itself there,
   because macOS ties its permissions to where it lives.)
3. A setup guide sits beside System Settings and shows each step:
   - **Accessibility**, so Navi notices your clicks during a lesson.
   - **Screen Recording**: drag Navi's tile into the list and switch it on. macOS
     applies it only after a restart, so the guide offers **Reopen Navi**.
   - **Claude**: press **Connect Claude**. Navi installs Claude Code from claude.ai
     (no Terminal needed), then your browser opens so you can sign in with your Claude
     plan. If you already use Claude Code, Navi finds it. You can use an API key instead,
     in Settings.

Navi then opens at login (you can switch that off in Settings) and keeps itself up to
date: it checks for a new version once a day and asks before installing it.

## Use

- **Tap right ⌥** (or **⌃⌥N**) and type your question. Navi looks at the screen you're
  on and answers beside it. Tap twice quickly to circle or mark something on screen
  first; your marks go with the question.
- **"How do I…"** questions become lessons: Navi rings the next thing to click, with a
  short reason. Click it and Navi looks again and shows the next one.
- **Lessons you put down are kept.** Stop partway and Navi keeps your place: the plan,
  the step you reached and where you got stuck. Ask about it again, even days later, and
  Navi picks it up, or choose it under **Carrying on** in the menu.
- **Give Navi your material.** Click the 📎 where you type, or drop lecture slides, a
  practical or a whole folder there or on the owl in the menu bar, and Navi uses them for
  the rest of the conversation. If you have a PDF or slides open when you ask, Navi offers
  to use it. You can also add files to a kept lesson in **History**.
- **"Let me try"** turns on practice: Navi asks, and you answer under the question or on
  screen, with Hint and Show me when you want them.
- **One conversation, as long as you're working.** Ask whenever you like, minutes or hours
  apart, and Navi remembers what you've been doing. The topic shows beside where you type;
  its **×**, or **New conversation** in the menu, starts fresh. After a long break Navi says
  what it's carrying on from, with **Start fresh** beside it.
- **Esc** stops what's on screen (an answer, a lesson, your marks).
- Navi can fetch things so a lesson isn't held up: open a page, an app or a file,
  download a file (after asking you), and copy a command, save a note or set a reminder
  when you ask.

Navi writes rather than speaks for now: there's no talking to it or reading aloud.

The menu bar owl holds what's used every day: **Ask Navi…**, **New conversation**,
**History…**, your kept lessons under **Carrying on**, a line on how the connection
stands (with **Fix…** when something needs you), **Report a problem…**, **Settings…**
and **Quit**. A small dot on the owl means Claude isn't reachable.

## Settings

One page, in cards:

- **Claude**: Claude Code or an API key, the model, how much it thinks, Navi's own
  sign-in (kept in your Keychain so it doesn't lapse), and connection details.
- **Asking**: the shortcut (⌃⌥N unless you choose another) and the key you tap to type.
  If another app already owns the shortcut, Navi says so and offers to change it.
- **On screen**: Navi's light, which follows the pointer.
- **Privacy**: whether the app's name, window and a short excerpt go with a question;
  whether Claude may look, read-only, at installed apps, files you mention or attach,
  and past conversations; permissions; History.
- **Teaching**: the Skills folder (what Navi knows and learns about your apps), and where saved notes go.
- **General**: open at login, crash reports, **Report a problem**, the version and
  **Check for updates**.
- **Advanced**: hand-drawn strokes, snapping to buttons, keeping Navi beside the
  pointer, and showing Navi in screen recordings.

## Privacy

- Your screen goes to Claude only when you ask something, with your question, and
  isn't kept.
- History keeps the text of your conversations for 7 days in
  `~/Library/Application Support/Navi/History/`. **Clear History…** deletes it.
- The conversation you're in is kept as text (never screenshots) in
  `~/Library/Application Support/Navi/conversation.json`, so a restart loses nothing.
  Starting fresh deletes it.
- Kept lessons are text only (the plan, steps, where you stopped, file names) in
  `~/Library/Application Support/Navi/bookmarks.json`. Each goes when it's finished,
  when you delete it, or after 30 days unused.
- Keys and sign-in tokens live only in your Keychain. Document excerpts are redacted
  for secrets before they're sent or saved, and Claude may never read key or credential
  files. Files in private places (keys, keychains, mail) can't be attached.
- If a password field is focused, Navi doesn't look at your screen.
- Crash reports stay on your Mac. **Report a problem** opens a GitHub issue for you to
  read over and submit; nothing is sent by itself.
- The daily update check fetches the release feed from GitHub and sends nothing about
  you or your Mac.

## Uninstall

1. Quit Navi (menu bar owl › **Quit**) and drag Navi from Applications to the Bin.
2. To remove everything it kept, delete `~/Library/Application Support/Navi/` and
   `~/Library/Logs/Navi.log`, and in **Keychain Access** delete the items whose names
   start with "Navi".
3. Optionally, remove Navi from System Settings › Privacy & Security › Accessibility
   and Screen Recording.

Claude Code stays installed (other apps may use it). To remove it too, delete
`~/.local/bin/claude` and `~/.local/share/claude/`.

## Reporting a problem

Use **Report a problem…** in the menu or Settings. It opens a
[new issue](https://github.com/remodivito/navi/issues/new) with your Navi and macOS
versions filled in. If Navi crashed, it offers **Report…** the next time it opens, with
a short summary of the crash. Issues are public, so leave out anything private.

## Build from source

```bash
./make-app.sh
```

builds Navi.app, signs it (with your Developer ID if you have one, else a local or
ad-hoc signature), quits a running Navi and installs the build to /Applications. A
build signed ad hoc may need its permissions granted again after each rebuild.

- `swift build` and `swift run Navi` for development.
- `swift run Navi --selftest` and `swift run navi-core-check` run the self-tests.
- `./make-release.sh` makes the notarised download: `dist/Navi-<version>.dmg`, with
  Navi beside an Applications shortcut, a zip, and `dist/appcast.xml`, the update feed
  signed with the maintainer's update key. Attach the DMG and the feed to a GitHub
  release tagged `v<version>`, and raise `CFBundleVersion` for each release.

`Sources/NaviCore` is the teaching logic (Foundation only, shared with the Windows
shell in progress); `Sources/NaviMac` draws it on the Mac. Claude answers with tags
that Navi parses into marks and steps; the grammar is in `Resources/Shared/tags.md`.

**Development builds keep screenshots.** An empty `.dev-build` file next to
`Package.swift` makes History also save the screenshots that were sent, with Claude's
marks redrawn on them. It's in `.gitignore` and must never be committed or shipped:
without it, as in any release, that code isn't compiled in. Run `swift package clean`
after adding or removing it.

## Licence

Apache License 2.0; see `LICENSE` and `NOTICE`. The bundled fonts (Figtree and
Patrick Hand) are under the SIL Open Font License, and Sparkle, the updater, under the
MIT licence; see `THIRD_PARTY_NOTICES.md`.

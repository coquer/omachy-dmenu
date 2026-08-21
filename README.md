# omachy-dmenu

A real dmenu clone for [Omarchy](https://omarchy.org/) 4 (Quattro),
integrated directly into the status bar itself — not a dropdown, not a
card, not a second bar. When summoned it paints a bar-colored segment
directly in the real bar, starting right after your workspace numbers and
never reaching past the screen's horizontal center, with matches laid out
left-to-right after the input exactly like vanilla `dmenu`/`dmenu_run`.
Matching semantics and the freeform "run whatever I typed" fallback are
also taken from actual dmenu (see [Behavior notes](#behavior-notes)
below).

Plugin id: `local.dmenu` · kind: `overlay` · repo:
[coquer/omachy-dmenu](https://github.com/coquer/omachy-dmenu) · license:
[MIT](LICENSE)

## Requirements

- **Omarchy 4 (Quattro)** — this plugin runs inside `omarchy-shell`
  (Quickshell) and depends on shared shell singletons (`qs.Commons`:
  `Color`, `Style`, `Util`, `Border`) and the shell's `AppLibrary` service
  that only exist there. It will not work as a standalone `quickshell -p`
  script beyond basic app filtering.
- **Hyprland**, as shipped with Omarchy (for the `SUPER + D` keybind and
  layer-shell overlay support).
- No other dependencies — pure QML, no external scripts. Application
  launches shell out to `uwsm-app`/`gtk-launch`, which ship with Omarchy.

## Install

**Recommended** — one command, using Omarchy's own plugin installer:

```bash
omarchy plugin add git@github.com:coquer/omachy-dmenu.git --enable
```

This clones the repo straight into `~/.config/omarchy/plugins/local.dmenu`,
validates the manifest, and enables it. Skip `--enable` if you'd rather
review the code first and enable it yourself later with
`omarchy plugin enable local.dmenu`.

**Manual alternative** — if you want to inspect or edit the code before
installing:

```bash
git clone git@github.com:coquer/omachy-dmenu.git
omarchy plugin validate omachy-dmenu
cp -r omachy-dmenu ~/.config/omarchy/plugins/local.dmenu
omarchy-shell shell rescanPlugins
omarchy plugin enable local.dmenu
```

### Verify it works

```bash
omarchy-shell shell toggle local.dmenu
```

You should see a bar-colored segment appear in the status bar, starting
right after your workspace numbers, with a cursor and your application
list running left-to-right after it, stopping before the screen's
horizontal center — the rest of the real bar (clock, tray, etc.) stays
visible and untouched. Run the same command again to close it.

## Key binding (manual step — can't be automated)

There's no Omarchy CLI command that adds an arbitrary Hyprland keybind for
you, and an installer script safely rewriting your personal
`~/.config/hypr/bindings.lua` unattended is exactly the kind of thing that
can silently clobber bindings you already rely on — so this part is on
you, once, by hand.

1. Check whether `SUPER + D` is already bound to something:
   ```bash
   omarchy menu keybindings --print | grep "SUPER + D"
   ```
2. Open `~/.config/hypr/bindings.lua`. If `SUPER + D` showed up above,
   unbind it first, then bind the launcher:
   ```lua
   hl.unbind("SUPER + D")
   o.bind("SUPER + D", "App launcher", "omarchy-shell shell toggle local.dmenu")
   ```
   If nothing was bound, skip the `hl.unbind` line.
3. Save. Hyprland auto-reloads, but validate it:
   ```bash
   hyprctl reload
   hyprctl configerrors
   ```

Pick a different key the same way if you'd rather not touch `SUPER + D`.

### Optional: a bar trigger instead of/alongside the keybind

This plugin only declares the `overlay` kind, so it isn't summonable from
the bar layout directly. If you want a clickable trigger too, the
simplest route is a bar `exec` widget (or any launcher button) running the
same IPC command: `omarchy-shell shell toggle local.dmenu`.

## Updating

If you installed via `omarchy plugin add` (git-managed):

```bash
omarchy plugin update local.dmenu
omarchy restart shell   # see "Editing/updating" below — required every time
```

If you installed manually, `git pull` in your clone and re-copy the
changed files, then restart the shell the same way.

## Editing/updating this plugin (important)

The manifest sets `keepLoaded: true`, so once mounted the plugin's window
stays alive for the rest of the shell session. Both the file-watcher's
automatic reload *and* `omarchy-shell shell rescanPlugins` only refresh
the plugin registry/manifest — neither one tears down and rebuilds an
already-mounted `keepLoaded` component. In practice this means: after the
*first* load, any change to `Dmenu.qml` — whether from `plugin update`,
`git pull`, or a local edit — will save/validate fine but won't actually
show up until you force a real restart:

```bash
omarchy restart shell
```

Do that after every update or edit rather than trusting the hot-reload —
otherwise you'll be looking at stale behavior and not know it.

## Customizing

Everything worth tweaking is a `property` near the top of `Dmenu.qml` —
remember to `omarchy restart shell` after editing (see above):

| What                      | Property                                         |
|---------------------------|---------------------------------------------------|
| Dock at bottom instead of top | `dockAtBottom` (default `false`, like dmenu's `-b`) |
| Bar height                | `barHeight` (default: the real bar's own `Style.bar.sizeHorizontal`) |
| Where the segment starts  | `leftOffset` (computed live — see [Positioning](#positioning) below) |
| Base part of `leftOffset` (menu icon, margins) | `leftBase` (default `40`) |
| Width per workspace pill  | `perWorkspaceWidth` (default the real widget's own `Style.space(20)`) |
| Highest workspace id counted | `maxWorkspaceId` (default `10`, matches the workspace widget's own default) |
| Gap before the bar's center modules | `centerGap` (default `100`) — see [Positioning](#positioning) below |
| Padding inside the segment | `sideMargin`                                      |
| Padding around each match | `itemPaddingX`                                     |
| Gap between matches       | `itemSpacing`                                      |
| Font                      | `fontFamily` (defaults to the shell's menu font)   |
| Colors                    | `background`, `foreground`, `selectedBackground`, `selectedText` — read from the real bar's own tokens (`Color.bar.*`) by default, so it matches the bar exactly |

### Positioning

`leftOffset` tracks your *current* workspace count live, rather than
being one fixed guess: `leftOffset = leftBase + workspaceCount *
perWorkspaceWidth`. A separate Wayland layer-shell surface still can't
query the real bar's live rendered widget width directly, but the
workspace widget (`i3-workspaces`/`omarchy.workspaces`) renders each
active workspace as a fixed-width pill with no gap between them
(`Style.space(20)`, no `columnSpacing`), so the *variable* part can be
computed from the same live Hyprland workspace data those widgets read
(`Quickshell.Hyprland`'s `Hyprland.workspaces`, filtered to the current
monitor and refreshed on every open) instead of measured once and left
stale. This is what fixed the "gap is too wide with only a few
workspaces active" issue — the offset now shrinks and grows with the
actual pill count instead of assuming a fixed number of them.

`leftBase` (default `40`) is the part that *doesn't* vary with workspace
count — bar edge margin, menu icon, module spacing — and is still a
measured constant, the same way `leftOffset` used to be entirely. If your
left section has different widgets before the workspace pills (or you
don't use `i3-workspaces`-style fixed-width pills at all), re-measure just
that base:

```bash
# crop a strip from the top-left corner and narrow the width until the
# first workspace number just disappears — that width is your leftBase
grim -g "0,0 60x30" /tmp/bar-check.png
```

The right edge is capped at the screen's horizontal center minus
`centerGap` (default `100`px), via the read-only `maxRightX`/
`contentWidth` properties — so the segment can never grow past that
regardless of how many matches there are, and there's always some
breathing room before the bar's center modules (clock, etc.). Increase
`centerGap` for more room, decrease it (down to `0`) to let the segment
reach all the way to center.

## Behavior notes

This launcher matches real dmenu's own semantics and shape, not a
fuzzy-search app-picker's — modeled on
[`i3-dmenu-desktop`](https://github.com/i3/i3/blob/next/i3-dmenu-desktop)
feeding names to the actual `dmenu` binary:

- **Layout**: a single flat segment integrated into the real status bar —
  not a floating card, not a second bar — prompt/input on the left,
  matches immediately after it running left-to-right, not a dropdown
  list. It starts right after your workspace numbers — tracking however
  many are actually active right now, not a fixed guess — and stops
  before the screen's horizontal center (see
  [Positioning](#positioning) above); the rest of the real bar stays
  visible on both sides.
- **Matching**: case-insensitive, and every space-separated term in your
  query must appear somewhere in the name (an AND search, e.g. `"fire fox"`
  matches "Firefox"). There is no fuzzy or acronym scoring. Results are
  bucketed exact match, then prefix match, then any other substring match —
  each bucket keeps the underlying dictionary order, same as dmenu's own
  `match()`.
- **Freeform exec (dmenu_run parity)**: if nothing matches your typed text
  and you press Enter, it runs the raw text as a shell command instead of
  doing nothing — the defining dmenu feature that makes it a command
  launcher, not just an app picker. If there *is* a match, Enter always
  launches the highlighted app instead, even if what you typed isn't the
  full name.
- The app list itself (names + hidden-entry filtering) comes from the
  shell's shared `AppLibrary` (same source the Omarchy menu's Apps submenu
  uses) when running inside `omarchy-shell` — only the *ranking* is
  reimplemented here to match dmenu instead of AppLibrary's fuzzy scorer.
  Falls back to `DesktopEntries` directly if `AppLibrary` isn't injected
  (e.g. loaded standalone with `quickshell -p`).
- Navigation: `Left`/`Right` (matches run horizontally, not vertically),
  `Tab`/`Shift+Tab`, and `Ctrl+J`/`Ctrl+K` (plain `j`/`k` are left alone
  since you're always typing a filter, like real dmenu).
- `Escape`, `Ctrl+C`, or clicking anywhere outside the visible segment all
  close without launching — a deliberate departure from real dmenu, which
  has no click-outside at all (its X11 grab makes the rest of the desktop
  unreachable while it's open, so the concept doesn't apply there). Here
  the surface spans the full bar width to hold the keyboard grab, so any
  click that lands outside the visible segment closes it instead of doing
  nothing.
- App launches use the same path as the Omarchy menu: `uwsm-app --
  gtk-launch <id>.desktop`. Freeform commands run directly via `bash -lc`.
- `keepLoaded: true` in the manifest keeps the window mounted between
  summons so repeat opens are instant (see the restart caveat above).

## Uninstalling

```bash
omarchy plugin remove local.dmenu
```

This disables the plugin and removes it from
`~/.config/omarchy/plugins/`. What exactly happens to the files depends on
how you installed it:

- **Installed via `omarchy plugin add`** (a git checkout): the folder is
  deleted outright — no local backup — since the code still exists in
  this upstream repo and can be re-added any time.
- **Installed manually** (plain copy, no `.git`): the folder is moved to a
  timestamped backup alongside it (e.g. `.local.dmenu.bak.<timestamp>`)
  rather than deleted, so nothing is lost if you copied over local edits.

No shell restart is needed afterward — unlike editing the plugin in
place, `plugin remove` disables it through the shell's own IPC before
touching the folder, so the `keepLoaded` window is properly torn down.

Finally, undo the keybind: remove (or repurpose) the `o.bind("SUPER + D",
...)` line you added to `~/.config/hypr/bindings.lua`, and its
`hl.unbind("SUPER + D")` above it if you added one, then `hyprctl reload`.

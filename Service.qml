import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.UPower
import QtQuick

// The Matrix pack's plugin: the same rain on the desktop and over Omarchy's
// screensaver.
//
// Additive on purpose. It neither clones nor disables omarchy.background: it
// draws on a layer-shell surface of its own above the wallpaper
// (WlrLayer.Bottom) and lets clicks through with `mask: Region {}`, the same
// idiom Omarchy itself uses in plugins/osd/Osd.qml and plugins/bar/Bar.qml.
// Omarchy's background stays alive underneath, theme transitions intact.
//
// The screensaver is additive in the same way. Omarchy opens its own
// screensaver and closes it again, and this plugin only draws the rain over it.

Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  // The filename comes from provider.json's slug. It is written here by hand
  // because QML cannot read the provider; tools/check.sh verifies the two agree.
  readonly property string configPath: home + "/.config/omarchy/enter-the-matrix.json"
  readonly property string backgroundLink: home + "/.local/state/omarchy/current/background"

  // --- our own settings -------------------------------------------------
  // They live in enter-the-matrix.json rather than shell.json on purpose: `omarchy
  // refresh shell` rewrites shell.json wholesale and would take these with it.
  property bool wantWallpaper: true
  property bool wantScreensaver: true

  // --- which background is selected --------------------------------------
  // The rain is picked like any other background in the carousel.
  // The live background is a real still from the film, and it doubles as the
  // thumbnail, as the marker, and as the fallback if the plugin is not running.
  // Matched by suffix, never by number: the carousel gets reordered (the default
  // is now a still from the film, so the rain no longer has to sort first) and
  // anything pinning "0-" silently stops raining when it does. That is exactly
  // how it broke once -- the background got selected, and nothing drew.
  readonly property string liveMarker: "-live-"
  property string currentBackground: ""
  readonly property bool rainIsBackground: String(currentBackground).indexOf(liveMarker) >= 0

  // --- the screensaver ----------------------------------------------------
  // Omarchy decides when, and this plugin only paints. At idle.screensaver
  // seconds, Omarchy's idle service runs omarchy-launch-screensaver. That opens
  // one fullscreen window per monitor, with the app id below.
  //
  // While such a window is open, the rain covers it. Stay Awake, the timings in
  // shell.json, idle inhibitors and the key that ends the screensaver all stay
  // Omarchy's. omarchy-system-lock closes the screensaver, so the rain goes too.
  //
  // Up to 1.2.0 the pack switched Omarchy's screensaver off and ran an idle
  // monitor of its own. A third-party service gets a scoped shell
  // (shell.qml:739-744) that cannot see Stay Awake, the timings or the lock.
  // That monitor never started, and no screensaver came up at all.
  readonly property string screensaverAppId: "org.omarchy.screensaver"
  readonly property bool screensaverOpen: {
    var toplevels = ToplevelManager.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      if (toplevels[i].appId === root.screensaverAppId) return true
    }
    return false
  }
  readonly property bool screensaverShowing: root.wantScreensaver && root.screensaverOpen

  function applyConfig(raw) {
    var parsed = ({})
    try { parsed = JSON.parse(raw || "{}") || ({}) } catch (e) { parsed = ({}) }
    root.wantWallpaper = parsed.wallpaper !== false
    root.wantScreensaver = parsed.screensaver !== false
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfig(text())
    // With no file the pack is complete: that is what install.sh leaves behind
    // and what anyone expects after `omarchy plugin add`.
    onLoadFailed: root.applyConfig("{}")
    onFileChanged: reload()
  }

  // The current background is a symlink that moves under our feet, so a
  // FileView will not do. It is re-read at startup, over IPC (omarchy-matrix
  // calls it) and on a slow poll as a safety net, because Omarchy's own
  // `background refresh` IPC is not ours to hook into.
  Process {
    id: readLink
    command: ["readlink", "-f", root.backgroundLink]
    stdout: StdioCollector {
      onStreamFinished: root.currentBackground = String(text || "").trim()
    }
  }

  function refreshBackground() {
    if (!readLink.running) readLink.running = true
  }

  Timer {
    interval: 3000
    repeat: true
    running: true
    onTriggered: root.refreshBackground()
  }

  IpcHandler {
    target: "matrix"

    function refresh(): void {
      root.refreshBackground()
      configFile.reload()
    }

    function status(): string {
      return JSON.stringify({
        wallpaper: root.wantWallpaper,
        screensaver: root.wantScreensaver,
        rainIsBackground: root.rainIsBackground,
        background: root.currentBackground,
        screensaverOpen: root.screensaverOpen,
        screensaverShowing: root.screensaverShowing
      })
    }
  }

  Component.onCompleted: root.refreshBackground()

  // --- layer 1: the live wallpaper ---------------------------------------
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: wallpaperPanel
      required property var modelData

      screen: modelData
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      visible: root.wantWallpaper && root.rainIsBackground

      // The rain starts from black every time the surface appears, rather than
      // resuming wherever it happened to be. The MatrixRain lives inside this
      // PanelWindow, which is never destroyed, so without this its clock
      // survives from one showing to the next and the wallpaper comes up
      // already at full pelt.
      onVisibleChanged: if (visible) wallpaperRain.restart()

      // Bottom and not Background: within one layer the order depends on
      // creation order, and that is not a race we want to run against
      // omarchy.background. Bottom sits above the wallpaper and below every
      // window, which is exactly the right place.
      WlrLayershell.namespace: "matrix-rain-wallpaper"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      // An empty region takes us out of input routing altogether, so clicks
      // reach Omarchy's desktop, which is what opens its menu.
      mask: Region {}

      // How many windows are on the active workspace OF THIS screen. The panel
      // is already per-screen, so the brake is per-screen too.
      readonly property int windowsHere: {
        try {
          var monitors = Hyprland.monitors.values
          for (var i = 0; i < monitors.length; i++) {
            if (monitors[i].name !== wallpaperPanel.modelData.name) continue
            var workspace = monitors[i].activeWorkspace
            if (!workspace || !workspace.lastIpcObject) return 0
            return workspace.lastIpcObject.windows || 0
          }
        } catch (e) {
          // If the shape of the IPC object ever changes, err on the cautious
          // side and assume something is covering the desktop.
          try { return ToplevelManager.toplevels.values.length } catch (e2) { return 1 }
        }
        return 0
      }

      MatrixRain {
        id: wallpaperRain
        anchors.fill: parent
        // The scanline is drawn in NATIVE pixels, so it needs this screen's
        // ratio and not the one the shell happens to be attached to.
        dpr: wallpaperPanel.modelData.devicePixelRatio
        // On mains it always rains; on battery, only while the desktop is
        // visible. Opening any window freezes it and the GPU drops to zero.
        // Note this stops the clock without restarting it: a frozen wallpaper
        // is meant to carry on where it left off, which is why restart() hangs
        // off `visible` above and not off `running`.
        running: wallpaperPanel.visible && (!UPower.onBattery || wallpaperPanel.windowsHere === 0)
      }
    }
  }

  // --- layer 2: the rain over Omarchy's screensaver ------------------------
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: screensaverPanel
      required property var modelData

      screen: modelData
      anchors { top: true; bottom: true; left: true; right: true }
      color: "black"
      visible: root.screensaverShowing

      // Every time the screensaver comes up it rains from nothing, not from
      // wherever the last one left it.
      onVisibleChanged: if (visible) screensaverRain.restart()

      // Overlay, so the rain sits above Omarchy's fullscreen screensaver window.
      WlrLayershell.namespace: "matrix-rain-screensaver"
      WlrLayershell.layer: WlrLayer.Overlay
      // No keyboard and no pointer. Every key and every mouse movement reaches
      // Omarchy's screensaver underneath, and that window alone decides when
      // it ends. It also hides the pointer itself (bin/omarchy-screensaver).
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      mask: Region {}

      MatrixRain {
        id: screensaverRain
        anchors.fill: parent
        dpr: screensaverPanel.modelData.devicePixelRatio
        running: screensaverPanel.visible
      }
    }
  }
}

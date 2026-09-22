import Quickshell
import Quickshell.Io
import Quickshell.Wayland
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
  readonly property string backgroundLink: home + "/.local/state/omarchy/current/background"

  // The plugin has no settings. Omarchy's choices decide both layers: the
  // background says whether the desktop rains, and Omarchy's idle service
  // says when the screensaver opens.

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

  // The current background is a symlink, and omarchy-theme-bg-set replaces it
  // with `ln -nsf`. A watch on the link would follow the old target, so this
  // watches the folder that holds the link. Each change runs one readlink.
  //
  // Omarchy's idle service watches the Stay Awake file the same way
  // (plugins/services/idle/Service.qml): a FileView on the folder, one probe
  // per change, and a reload of the watch after each probe.
  FileView {
    id: backgroundDir
    path: root.home + "/.local/state/omarchy/current"
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshBackground()
  }

  // A theme change swaps the theme folder and then the link, close together.
  // A change that arrives during a read is kept, and read after it, so the
  // last swap always wins.
  property bool backgroundPending: false

  Process {
    id: readLink
    command: ["readlink", "-f", root.backgroundLink]
    stdout: StdioCollector {
      onStreamFinished: root.currentBackground = String(text || "").trim()
    }
    onExited: function() {
      if (root.backgroundPending) {
        root.backgroundPending = false
        readLink.running = true
        return
      }
      backgroundDir.reload()
    }
  }

  function refreshBackground() {
    if (readLink.running) {
      root.backgroundPending = true
      return
    }
    readLink.running = true
  }

  IpcHandler {
    target: "matrix"

    function refresh(): void {
      root.refreshBackground()
    }

    function status(): string {
      return JSON.stringify({
        rainIsBackground: root.rainIsBackground,
        background: root.currentBackground,
        screensaverOpen: root.screensaverOpen
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
      // Black, not transparent: while the rain holds its first second the
      // shader is hidden, and a transparent panel would show Omarchy's still
      // underneath instead of black. The shader paints opaque when it rains,
      // so this black never leaks into the normal display. Clicks still pass
      // through with `mask: Region {}` below; colour does not affect input.
      color: "black"
      visible: root.rainIsBackground

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

      MatrixRain {
        id: wallpaperRain
        anchors.fill: parent
        startDelayMs: 1000
        // The scanline is drawn in NATIVE pixels, so it needs this screen's
        // ratio and not the one the shell happens to be attached to.
        dpr: wallpaperPanel.modelData.devicePixelRatio
        // Always raining while the rain is the background, on mains and on
        // battery, windows open or not. Restart with the hold whenever the
        // rain starts running again, the same as the screensaver below.
        running: wallpaperPanel.visible
        onRunningChanged: if (running) restart()
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
      visible: root.screensaverOpen

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
        startDelayMs: 1000
        running: screensaverPanel.visible
        // `visible` and `running` flip in the same pass and the order is not
        // guaranteed: if onVisibleChanged runs first, restart() still sees
        // running=false and skips the hold. Restart here too, where running
        // is already true; two restarts in one pass are idempotent. The
        // wallpaper carries the same handler: the rain runs always while
        // the rain is the background.
        onRunningChanged: if (running) restart()
      }
    }
  }
}

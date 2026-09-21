import QtQuick

// Digital rain, on the GPU.
//
// It is a single full-screen ShaderEffect: matrix.frag.qsb does the work and
// all that happens here is handing it the clock, the size and the colours.
// An earlier version drew into a QML Canvas and never convinced: repainting
// cell by cell forces a choice between too few characters and burning CPU, and
// the trail never looked right.
//
// The shader comes from bjarneo/quickshell (MIT), with its procedural glyphs
// swapped for an atlas of the real katakana ttfx uses. See tools/matrix.frag.
//
// running=false stops the clock: with no property changing, the ShaderEffect
// does not render again, so the GPU drops to zero and the last frame stays
// frozen on screen.

Item {
  id: root

  property bool running: true
  // Frames per second at which the shader's clock advances.
  property int fps: 30
  // Cell height in logical px. 32 is the row pitch of the real screensaver
  // (64 native px on a panel at scale 2); the shader derives the width from it.
  property real cellHeight: 32

  // Straight from `ttfx matrix`: --highlight-color and --rain-color-gradient.
  // Tuned toward CRT phosphor bloom (film-accurate A).
  property color bgColor: "#000000"
  property color headColor: "#E2FFE2"
  property color rainA: "#7EBB7E"
  property color rainB: "#0E3A12"

  // Native pixels per logical pixel. The scanline is drawn against this rather
  // than against logical px, so it stays two real pixels wide on any panel.
  // A caller that knows its ShellScreen should pass that screen's ratio; this
  // fallback is for one that does not, such as the lock.
  property real dpr: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1

  // --- the two clocks -----------------------------------------------------
  // `elapsed` wraps at `period`, and the shader is built so that every column
  // completes a whole number of falls in that time -- so the wrap is invisible.
  // Without it `elapsed` grows without bound and the uniform is a float32: at
  // 18 rows a second, a day of running time puts the step at an eighth of a
  // row and the fall starts to judder.
  //
  // The price is that the whole field repeats exactly every `period`, and that
  // price is not negotiable: a rain that never repeated would need speeds that
  // are not commensurate, and those leave the clock nowhere to wrap. So the
  // repeat is pushed past anyone's attention span instead of being removed.
  //
  // An hour, and not two minutes, because two minutes was visible -- the same
  // field came back while you were still looking at it. `k` in the shader
  // scales with this, so speed (k*span/period) and cycle length (period/k) do
  // not move: only the repeat does. Above an hour, float32 starts to quantise
  // the fall.
  property real period: 3600
  property real elapsed: 0

  // `birth` is the OTHER clock, and it exists because a cold start cannot be
  // expressed in the wrapped one: anything keyed to `elapsed` would happen
  // again at every wrap. This one counts from the moment the surface appeared
  // and stops for good just past the shader's BIRTH_SPREAD, so the rain falls
  // in from the top once and never again.
  // Capped past the longest a column can wait to begin its first cycle, which
  // is period/k for the slowest column. Beyond this the cold-start gate in the
  // shader is 1 for ever, which is what keeps it out of the wrap.
  readonly property real birthMax: 13.0
  property real birth: 0

  // Start over: black screen, then the columns arrive from the top.
  //
  // Deliberately NOT tied to `running`. On battery the wallpaper's clock stops
  // whenever a window covers the desktop, and there freezing and resuming is
  // exactly what is wanted. What restarts the rain is the surface BECOMING
  // VISIBLE, which only the caller knows about.
  function restart() {
    root.elapsed = 0
    root.birth = 0
  }

  Image {
    id: atlasImage
    source: Qt.resolvedUrl("glyphs.png")
    visible: false
    smooth: true
  }

  ShaderEffect {
    anchors.fill: parent
    fragmentShader: Qt.resolvedUrl("matrix.frag.qsb")

    // The names have to match those in the shader's uniform block.
    property real iTime: root.elapsed
    // `size` and not `vector2d`: that is the type Qt maps a vec2 to inside a
    // ShaderEffect without surprises.
    property size iResolution: Qt.size(width, height)
    property color colBg: root.bgColor
    property color colHead: root.headColor
    property color colRainA: root.rainA
    property color colRainB: root.rainB
    property real cellH: root.cellHeight
    property real dpr: root.dpr
    property real period: root.period
    property real birth: root.birth
    property variant atlas: atlasImage
  }

  // FrameAnimation and not Timer. With a Timer the clock did advance (proved
  // with logs: elapsed kept rising) but the ShaderEffect never repainted, so
  // the rain came out drawn and frozen. FrameAnimation is wired into the render
  // loop, which is exactly what it takes for a new frame to appear.
  //
  // Since it runs at the monitor's refresh rate (144 Hz on the external screen)
  // and this is a background, time is accumulated but only published to
  // `elapsed` at `fps`: the shader sees 30 steps per second, not 144.
  FrameAnimation {
    id: clock
    running: root.running
    property real accumulated: 0
    onTriggered: {
      accumulated += frameTime
      var step = 1 / Math.max(1, root.fps)
      if (accumulated >= step) {
        root.elapsed = (root.elapsed + accumulated) % root.period
        if (root.birth < root.birthMax)
          root.birth = Math.min(root.birthMax, root.birth + accumulated)
        accumulated = 0
      }
    }
  }
}

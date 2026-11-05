import QtQuick
import qs.Commons

// Wheel and touchpad scrolling for a Flickable. The touchpad moves the
// content with the fingers, pixel for pixel, and keeps going when they lift
// (libinput sends no momentum, so the glide is ours, through Flickable's
// own deceleration). A wheel notch glides instead of jumping.
WheelHandler {
  id: wheel
  required property Flickable flick
  // A wheel notch, in pixels.
  property real step: Style.space(54)
  signal scrolled()

  acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

  property real velocity: 0
  property double lastTime: 0
  property bool fingers: false

  readonly property real maxY: Math.max(0, flick.contentHeight - flick.height)

  function release() {
    lift.stop()
    // A pause before lifting means the fingers had stopped: no fling.
    if (fingers && Date.now() - lastTime < 80 && Math.abs(velocity) > 100) flick.flick(0, velocity)
    fingers = false
    velocity = 0
  }

  // A handler takes no children: the animation and the timer are properties.
  readonly property NumberAnimation glide: NumberAnimation {
    target: wheel.flick
    property: "contentY"
    duration: 120
    easing.type: Easing.OutCubic
  }

  // For a touchpad that reports no scroll phases: no event for 60 ms is a lift.
  readonly property Timer lift: Timer {
    interval: 60
    onTriggered: wheel.release()
  }

  onWheel: function(event) {
    wheel.scrolled()
    var phase = event.phase === undefined ? Qt.NoScrollPhase : event.phase
    // The device and the phase say "touchpad", not whether this one event
    // happened to carry pixels, so a slow finger never turns into notches.
    var touch = fingers || phase !== Qt.NoScrollPhase || event.pixelDelta.y !== 0
      || (event.device && event.device.type === PointerDevice.TouchPad)
    if (touch) {
      glide.stop()
      if (phase === Qt.ScrollBegin) { flick.cancelFlick(); fingers = true; velocity = 0 }
      if (phase === Qt.ScrollEnd) { release(); event.accepted = true; return }
      if (!fingers) flick.cancelFlick()
      fingers = true
      var dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 8
      var now = Date.now()
      var dt = Math.max(4, now - lastTime)
      // Smoothed px/s, positive toward the top, as Flickable.flick takes it.
      velocity = dt > 100 ? 0 : 0.6 * (dy * 1000 / dt) + 0.4 * velocity
      lastTime = now
      flick.contentY = Math.max(0, Math.min(maxY, flick.contentY - dy))
      if (phase === Qt.NoScrollPhase) lift.restart()
    } else {
      // Quick notches add up: each one extends the glide already running.
      var from = glide.running ? glide.to : flick.contentY
      glide.stop()
      glide.from = flick.contentY
      glide.to = Math.max(0, Math.min(maxY, from - event.angleDelta.y / 120 * step))
      glide.start()
    }
    event.accepted = true
  }
}

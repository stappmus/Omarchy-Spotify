import QtQuick
import Quickshell
import "." as Plugin

ShellRoot {
  property var completed: []
  Plugin.SpotifyConnectManager {
    id: receiver
    pluginDir: decodeURIComponent(String(Qt.resolvedUrl("."))).replace(/^file:\/\//, "").replace(/\/$/, "")
    activating: true
    onControlled: function(device, action, value) {
      completed = completed.concat([action + ":" + value])
      if (completed.length === 4) {
        if (JSON.stringify(completed) !== JSON.stringify(["volume:25", "next:", "next:", "mode:SHUFFLE_REPEAT_ONE"]))
          throw new Error("Incorrect asynchronous control order")
        receiver.control("speaker123", "pause", "")
        receiver.discardQueuedControls()
        finish.start()
      } else if (completed.length > 4) throw new Error("Stale completion survived generation change")
    }
  }
  Timer {
    interval: 1
    running: true
    onTriggered: {
      if (receiver.control("bad", "play", "")) throw new Error("Invalid target accepted")
      receiver.control("speaker123", "volume", "10")
      receiver.control("speaker123", "volume", "25")
      receiver.control("speaker123", "next", "")
      receiver.control("speaker123", "next", "")
      receiver.control("speaker123", "mode", "SHUFFLE_REPEAT_ONE")
      receiver.activating = false
    }
  }
  Timer {
    id: finish
    interval: 300
    onTriggered: {
      if (receiver.controlBusy) throw new Error("Helper did not finish")
      console.log("CONNECT_CONTROLS_PASS")
      Qt.quit()
    }
  }
  Timer {
    interval: 5000
    running: true
    onTriggered: { throw new Error("Queued speaker controls never drained") }
  }
}

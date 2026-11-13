import QtQuick
import Quickshell
import "../.." as Plugin

ShellRoot {
  property int logoutCount: 0
  property bool waiterFinished: false
  Plugin.AuthManager {
    id: delayed
    pluginDir: "/nonexistent"
    settingsReady: false
    onLoggedOut: logoutCount++
  }
  Plugin.AuthManager {
    id: immediate
    pluginDir: "/nonexistent"
    clientId: "22222222222222222222222222222222"
  }
  Timer {
    interval: 1
    running: true
    onTriggered: {
      delayed.withAccessToken(function(token, reason) {
        if (token || !reason) throw new Error("Empty keyring incorrectly authenticated")
        waiterFinished = true
      })
      if (waiterFinished) throw new Error("Request bypassed delayed settings")
      delayed.customClientId = "11111111111111111111111111111111"
      delayed.settingsReady = true
    }
  }
  Timer {
    interval: 300
    running: true
    onTriggered: {
      if (!waiterFinished || !delayed.sessionChecked || !immediate.sessionChecked)
        throw new Error("Startup session lookup did not settle")
      if (logoutCount !== 0) throw new Error("Initial identity load emitted logout")
      delayed.customClientId = "33333333333333333333333333333333"
      if (logoutCount !== 1) throw new Error("Real identity change did not invalidate session")
      console.log("AUTH_STARTUP_PASS")
      Qt.quit()
    }
  }
}

import QtQuick
import Quickshell
import "." as Plugin

ShellRoot {
  id: test
  property int phase: 0
  Plugin.NativeSession {
    id: auth
    pluginDir: decodeURIComponent(String(Qt.resolvedUrl("."))).replace(/^file:\/\//, "").replace(/\/$/, "")
    enabled: true
    openBrowserAutomatically: false
  }
  Timer {
    interval: 20
    repeat: true
    running: true
    onTriggered: {
      if (test.phase === 0 && auth.initialized && auth.sessionChecked) {
        if (auth.loggedIn || auth.lastError) throw new Error("Fresh install did not settle signed out")
        test.phase = 1
        auth.beginLogin()
      } else if (test.phase === 1 && auth.pairingCode) {
        test.phase = 2
        auth.cancelLogin()
      } else if (test.phase === 2 && !auth.initialized && !auth.loginBusy) {
        if (auth.pairingCode || auth.loggedIn) throw new Error("Cancel retained login state")
        test.phase = 3
        auth.beginLogin()
      } else if (test.phase === 3 && auth.loggedIn) {
        if (auth.loginBusy || auth.pairingCode || auth.loginUrl) throw new Error("Login prompt did not clear")
        test.phase = 4
        auth.request("GET", "/me/tracks", {limit: 3}, null, function(status, data, error) {
          if (status !== 200 || error || data.path !== "/me/tracks") throw new Error("Native request did not complete")
          test.phase = 5
          auth.logout()
        })
      } else if (test.phase === 5 && !auth.initialized) {
        if (auth.loggedIn || auth.loginBusy || Object.keys(auth.pending).length) throw new Error("Logout retained state or requests")
        console.log("NATIVE_SESSION_PASS")
        Qt.quit()
      }
    }
  }
  Timer { interval: 6000; running: true; onTriggered: { throw new Error("Native session test stalled in phase " + test.phase) } }
}

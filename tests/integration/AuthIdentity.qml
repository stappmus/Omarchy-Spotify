import QtQuick
import Quickshell
import "../.." as Plugin

ShellRoot {
  Plugin.AuthManager { id: auth; pluginDir: "/nonexistent"; clientId: "11111111111111111111111111111111"; settingsReady: false }
  function check(condition, message) {
    if (!condition) throw new Error(message)
  }
  Timer {
    interval: 1
    running: true
    onTriggered: {
    var queued = false
    auth.withAccessToken(function() { queued = true })
    check(!queued && !auth.initialized, "Token request bypassed settings gate")
    auth.customClientId = "invalid"
    auth.settingsReady = true
    check(queued && auth.sessionChecked, "Invalid startup did not settle waiters")
    auth.customClientId = "11111111111111111111111111111111"
    auth.accessToken = "old"
    auth.accessTokenExpiresAt = Date.now() + 3600000
    auth.loggedIn = true
    auth.customClientId = "invalid"
    check(auth.accessToken === "", "Old access token survived identity change")
    check(!auth.loggedIn && !auth.validClientId, "Invalid identity was accepted")
    check(auth.resolvedClientId === "", "Invalid identity fell back silently")
    var error = ""
    auth.withAccessToken(function(token, reason) {
      check(token === "", "Old identity token reached a consumer")
      error = reason
    })
    check(error.indexOf("32") >= 0, "Invalid ID has no actionable error")
    var request = {
      readyState: 1, status: 200, responseText: "{}", aborted: false,
      open: function() {}, setRequestHeader: function() {}, send: function() {},
      abort: function() { this.aborted = true }
    }
    auth.xhrFactory = function() { return request }
    auth.customClientId = "11111111111111111111111111111111"
    var delivered = false
    auth.postTokenRequest("", "", function() { delivered = true })
    auth.customClientId = "invalid"
    request.readyState = XMLHttpRequest.DONE
    request.onreadystatechange()
    check(request.aborted, "Old token request was not aborted")
    check(!delivered, "Old identity response reached a new identity")
    console.log("AUTH_IDENTITY_PASS")
    Qt.quit()
    }
  }
}

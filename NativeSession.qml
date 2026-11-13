import QtQuick
import Quickshell
import Quickshell.Io
import "Api.js" as Api

// One private backend process owns account login and browsing. Playback reads
// the same reusable credential. Tokens never enter settings or command lines.
Item {
  id: root
  visible: false
  required property string pluginDir
  property bool enabled: false
  property bool openBrowserAutomatically: true
  property bool wanted: true
  property bool initialized: false
  property bool loggedIn: false
  property bool sessionChecked: true
  property bool sessionBusy: false
  property bool loginBusy: false
  property string lastError: ""
  property string pairingCode: ""
  property string loginUrl: ""
  property bool restartLogin: false
  property int serial: 0
  property var pending: ({})
  property var waiters: []
  readonly property bool validClientId: true // Compatibility with older panel hosts.
  function identityError() { return "" }
  function tokenIsFresh() { return loggedIn }
  signal loginSucceeded()
  signal loggedOut()
  signal sessionUnavailable(string reason)

  function finishWaiters(token, error) {
    var queued = waiters
    waiters = []
    for (var i = 0; i < queued.length; ++i) queued[i](token, error)
  }
  function resetPending(reason) {
    var old = pending
    pending = ({})
    for (var id in old) old[id].callback(0, null, reason)
    finishWaiters("", reason)
  }
  function send(command, fields, callback) {
    if (!worker.running || !initialized) { callback(0, null, "Spotify is starting"); return 0 }
    var id = ++serial
    var next = Object.assign({}, pending)
    next[String(id)] = {callback: callback, deadline: Date.now() + (command === "login" ? 3600000 : 45000)}
    pending = next
    var message = Object.assign({id:id, command:command}, fields || {})
    worker.write(JSON.stringify(message) + "\n")
    return id
  }
  function settle(status, data, error) {
    loginBusy = false
    sessionBusy = false
    sessionChecked = true
    pairingCode = ""
    loginUrl = ""
    loggedIn = status === 200 && data && data.logged_in === true
    lastError = error || ""
    finishWaiters(loggedIn ? "native-session" : "", lastError || "Log in to Spotify first")
    if (loggedIn) loginSucceeded()
    else if (lastError) sessionUnavailable(lastError)
  }
  function handleLine(line) {
    var message = Api.parseJson(line, null)
    if (!message) return
    if (message.type === "pairing" && loginBusy && pending[String(message.id)]) {
      var url = String(message.url || "")
      if (!/^https:\/\/(accounts\.spotify\.com|www\.spotify\.com|spotify\.com)\//.test(url)) return
      loginUrl = url
      pairingCode = String(message.code || "")
      if (openBrowserAutomatically) openLoginPage()
      return
    }
    if (message.type !== "response") return
    var id = String(message.id)
    var request = pending[id]
    if (!request) return
    var next = Object.assign({}, pending)
    delete next[id]
    pending = next
    request.callback(Number(message.status), message.data, Api.redact(String(message.error || "")))
  }
  function openLoginPage() {
    if (!loginUrl || browser.running) return
    browser.command = ["xdg-open", loginUrl]
    browser.running = true
  }
  function beginLogin() {
    if (loginBusy) return
    if (!enabled) { lastError = "Playback support is still being installed"; sessionUnavailable(lastError); return }
    lastError = ""
    loggedIn = false
    loggedOut()
    resetPending("Signing in to Spotify")
    loginBusy = true
    sessionBusy = false
    sessionChecked = false
    if (worker.running) { restartLogin = true; wanted = false }
    else wanted = true
  }
  function cancelLogin() {
    restartLogin = false
    loginBusy = false
    pairingCode = ""
    loginUrl = ""
    wanted = false
    sessionChecked = true
    resetPending("Sign-in cancelled")
  }
  function restoreSession() {
    if (!enabled || loginBusy || sessionBusy) return
    sessionChecked = false
    wanted = true
    if (initialized) { sessionBusy = true; send("status", {}, settle) }
  }
  function logout() {
    lastError = ""
    restartLogin = false
    loggedIn = false
    loginBusy = false
    sessionBusy = false
    sessionChecked = true
    pairingCode = ""
    loginUrl = ""
    resetPending("Signed out of Spotify")
    if (initialized) send("logout", {}, function() { root.wanted = false })
    else wanted = false
    loggedOut()
  }
  function withAccessToken(callback) {
    // Legacy callers use this only as a readiness gate. No Web API grant exists.
    if (loggedIn) { callback("native-session", ""); return }
    if (!sessionChecked && enabled) { waiters = waiters.concat([callback]); return }
    callback("", lastError || "Log in to Spotify first")
  }
  function withStreamingToken(callback) {
    send("token", {}, function(status, data, error) { callback(status === 200 && data ? data.token : "", error) })
  }
  function request(method, path, query, body, callback) {
    var cancelled = false
    var requestId = 0
    var handle = {abort: function() {
      cancelled = true
      if (!requestId) return
      var next = Object.assign({}, root.pending)
      delete next[String(requestId)]
      root.pending = next
      if (root.initialized) root.send("cancel_request", {request_id: requestId}, function() {})
    }}
    withAccessToken(function(session, error) {
      if (cancelled) return
      if (!session) { callback(401, null, error); return }
      requestId = root.send("request", {method:method, path:path, query:query, body:body}, function(status, data, reason) {
        if (!cancelled) callback(status, data, reason)
      })
    })
    return handle
  }
  Process {
    id: worker
    command: [root.pluginDir + "/scripts/native-session.sh"]
    running: root.enabled && root.wanted
    stdinEnabled: true
    onStarted: {
      root.sessionChecked = false
      root.initialized = true
      root.sessionBusy = !root.loginBusy
      root.send(root.loginBusy ? "login" : "status", {}, root.settle)
    }
    stdout: SplitParser { onRead: line => root.handleLine(line) }
    stderr: StdioCollector {} // Backend errors are returned as structured responses.
    onExited: (code, status) => {
      root.loggedIn = false
      root.initialized = false
      root.sessionBusy = false
      root.resetPending("Spotify session stopped")
      if (root.restartLogin) {
        root.restartLogin = false
        Qt.callLater(function() { root.wanted = true })
      } else {
        root.sessionChecked = true
        root.loginBusy = false
        if (root.wanted) {
          root.wanted = false
          root.lastError = "Spotify session stopped. Click Log in to reconnect."
          root.sessionUnavailable(root.lastError)
        }
      }
    }
  }
  Process { id: browser }
  Timer {
    interval: 1000
    repeat: true
    running: Object.keys(root.pending).length > 0
    onTriggered: {
      var next = Object.assign({}, root.pending)
      var expired = []
      for (var id in next) if (next[id].deadline < Date.now()) { expired.push(next[id]); delete next[id] }
      root.pending = next
      for (var i = 0; i < expired.length; ++i) expired[i].callback(0, null, "Spotify request timed out")
    }
  }
}

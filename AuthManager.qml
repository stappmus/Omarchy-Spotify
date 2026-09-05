import QtQuick
import Quickshell
import Quickshell.Io

import "Api.js" as Api
import "OAuth.js" as OAuth

// OAuth and token storage live here so the rest of the plugin never needs to
// know what a refresh token looks like. Access tokens exist only in memory;
// refresh tokens cross the process boundary over stdin and are persisted by
// GNOME Keyring.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  required property string pluginDir
  // spotify-player and ncspot use the defaults below for Web API login.
  // A second internal instance may override them for the streaming-only grant
  // required by authorization-code Spotify Connect receivers such as Sonos.
  property string clientId: "d420a117a32841c2b3474932e49fb54b"
  // A personal Spotify Developer app client ID opts out of the shared
  // per-app rate-limit bucket. Empty keeps the shipped client above. Only a
  // 32-hex value is accepted, so a typo can never redirect the OAuth flow or
  // the keyring entry (both are scoped per client ID).
  property string customClientId: ""
  readonly property string resolvedClientId: /^[0-9a-f]{32}$/i.test(String(customClientId || ""))
    ? customClientId.toLowerCase() : clientId
  property int oauthPort: 8989
  property string callbackPath: "/login"
  property var scopes: Api.SCOPES
  readonly property string redirectUri: "http://127.0.0.1:"
    + OAuth.normalizedPort(oauthPort) + callbackPath

  property string accessToken: ""
  property double accessTokenExpiresAt: 0
  property bool loggedIn: false
  property bool sessionChecked: false
  property bool loginBusy: false
  property bool refreshBusy: false
  readonly property bool sessionBusy: refreshBusy || secretLookup.running
  property string lastError: ""

  property var tokenWaiters: []
  property string lookupPurpose: ""
  property bool lookupHandled: false
  property string keyringWriteToken: ""

  property string pkceVerifier: ""
  property string pkceChallenge: ""
  property string oauthState: ""
  property bool callbackHandled: false
  property bool exchangingCode: false
  property var tokenRequest: null
  property int tokenRequestSerial: 0
  property bool logoutPendingClear: false

  signal loginSucceeded()
  signal loggedOut()
  signal sessionUnavailable(string reason)

  function safeError(value) {
    return Api.redact(String(value || ""))
  }

  function tokenIsFresh() {
    return accessToken !== "" && Date.now() + 60000 < accessTokenExpiresAt
  }

  function resetMemorySession() {
    accessToken = ""
    accessTokenExpiresAt = 0
    loggedIn = false
  }

  function invalidateAccessToken() {
    accessToken = ""
    accessTokenExpiresAt = 0
  }

  function finishWaiters(token, error) {
    var pending = tokenWaiters.slice()
    tokenWaiters = []
    for (var i = 0; i < pending.length; i++) {
      try { pending[i](token || "", safeError(error)) }
      catch (e) { /* consumers own their callback errors */ }
    }
  }

  function withAccessToken(callback) {
    if (typeof callback !== "function") return
    if (tokenIsFresh()) {
      callback(accessToken, "")
      return
    }

    var next = tokenWaiters.slice()
    next.push(callback)
    tokenWaiters = next
    if (refreshBusy || secretLookup.running) return

    lookupPurpose = "request"
    startSecretLookup()
  }

  function restoreSession() {
    sessionChecked = false
    if (secretLookup.running || refreshBusy) return
    lookupPurpose = "restore"
    startSecretLookup()
  }

  function startSecretLookup() {
    lookupHandled = false
    secretLookup.command = [
      "secret-tool", "lookup",
      "service", "quickshell-spotify",
      "kind", "refresh-token",
      "client-id", String(resolvedClientId)
    ]
    secretLookup.running = true
  }

  function handleSecretLookup(raw) {
    if (lookupHandled) return
    lookupHandled = true
    var token = String(raw || "").trim()
    var purpose = lookupPurpose
    lookupPurpose = ""
    if (!token) {
      resetMemorySession()
      sessionChecked = true
      if (purpose === "request") finishWaiters("", "Log in to Spotify first")
      return
    }
    refreshWithToken(token, purpose)
  }

  function postTokenRequest(body, previousRefreshToken, callback) {
    var serial = ++tokenRequestSerial
    var request = new XMLHttpRequest()
    tokenRequest = request
    request.onreadystatechange = function() {
      if (request.readyState !== XMLHttpRequest.DONE) return
      if (serial !== root.tokenRequestSerial) return
      if (root.tokenRequest === request) root.tokenRequest = null
      var result = OAuth.parseTokenResponse(request.status, request.responseText,
        previousRefreshToken)
      if (typeof callback === "function") callback(result)
    }
    request.open("POST", Api.TOKEN_URL)
    request.setRequestHeader("Content-Type", "application/x-www-form-urlencoded")
    request.send(body)
  }

  function refreshWithToken(refreshToken, purpose) {
    refreshBusy = true
    postTokenRequest(Api.formBody({
      client_id: resolvedClientId,
      grant_type: "refresh_token",
      refresh_token: refreshToken
    }), refreshToken, function(result) {
      refreshToken = ""
      root.refreshBusy = false
      root.sessionChecked = true
      if (!result.ok) {
        root.resetMemorySession()
        root.lastError = root.safeError(result.error)
        if (result.invalidGrant) root.clearStoredToken()
        if (purpose === "request") root.finishWaiters("", root.lastError)
        else root.sessionUnavailable(root.lastError)
        return
      }
      root.acceptToken(result)
      root.finishWaiters(root.accessToken, "")
    })
  }

  function acceptToken(result) {
    accessToken = result.accessToken
    accessTokenExpiresAt = Date.now() + result.expiresIn * 1000
    loggedIn = true
    lastError = ""
    if (result.refreshToken) storeRefreshToken(result.refreshToken)
  }

  function storeRefreshToken(refreshToken) {
    if (!refreshToken || keyringStore.running) return
    keyringWriteToken = String(refreshToken)
    keyringStore.command = [pluginDir + "/scripts/keyring-store.sh", String(resolvedClientId)]
    keyringStore.running = true
  }

  function clearStoredToken() {
    if (keyringClear.running) return
    keyringClear.command = [
      "secret-tool", "clear",
      "service", "quickshell-spotify",
      "kind", "refresh-token",
      "client-id", String(resolvedClientId)
    ]
    keyringClear.running = true
  }

  function logout() {
    cancelLogin()
    resetMemorySession()
    sessionChecked = true
    lastError = ""
    finishWaiters("", "Logged out")
    if (keyringStore.running) logoutPendingClear = true
    else clearStoredToken()
    loggedOut()
  }

  function beginLogin() {
    if (loginBusy || refreshBusy) return
    lastError = ""
    loginBusy = true
    callbackHandled = false
    exchangingCode = false
    pkceGenerator.command = [pluginDir + "/scripts/pkce.sh"]
    pkceGenerator.running = true
  }

  function handlePkce(raw) {
    if (!loginBusy || pkceVerifier !== "") return
    var result = OAuth.parsePkceOutput(raw)
    if (!result.ok) {
      failLogin("Could not start a secure Spotify sign-in. Please try again")
      return
    }
    pkceVerifier = result.verifier
    pkceChallenge = result.challenge
    oauthState = result.state
    callbackListener.command = [
      "socat", "-T", "180",
      "TCP4-LISTEN:" + OAuth.normalizedPort(oauthPort) + ",bind=127.0.0.1,reuseaddr",
      "STDIO"
    ]
    callbackListener.running = true
    authTimeout.restart()
  }

  function openAuthorizationPage() {
    if (!loginBusy || callbackHandled || pkceChallenge === "") return
    var url = Api.appendQuery(Api.AUTH_URL, {
      client_id: resolvedClientId,
      code_challenge: pkceChallenge,
      code_challenge_method: "S256",
      redirect_uri: redirectUri,
      response_type: "code",
      scope: (Array.isArray(scopes) ? scopes : Api.SCOPES).join(" "),
      state: oauthState,
      show_dialog: "true"
    })
    Quickshell.execDetached(["xdg-open", url])
  }

  function handleCallbackLine(rawLine) {
    if (!loginBusy || callbackHandled) return
    var line = String(rawLine || "").replace(/\r$/, "")
    if (line.indexOf("GET ") !== 0) return
    callbackHandled = true
    authTimeout.stop()
    var callback = OAuth.parseCallbackRequestLine(line, callbackPath)
    if (!callback.ok || callback.state !== oauthState) {
      callbackListener.write(OAuth.failureResponse())
      callbackStopTimer.restart()
      failLogin(callback.ok
        ? "Spotify sign-in could not be verified. Please try again"
        : callback.error, true)
      return
    }
    callbackListener.write(OAuth.successResponse())
    callbackStopTimer.restart()
    exchangeAuthorizationCode(callback.code)
  }

  function exchangeAuthorizationCode(code) {
    exchangingCode = true
    var verifier = pkceVerifier
    var requestBody = Api.formBody({
      client_id: resolvedClientId,
      code: code,
      code_verifier: verifier,
      grant_type: "authorization_code",
      redirect_uri: redirectUri
    })
    code = ""
    verifier = ""
    clearPkce()

    postTokenRequest(requestBody, "", function(result) {
      root.exchangingCode = false
      root.loginBusy = false
      if (!result.ok) {
        root.lastError = root.safeError(result.error)
        root.sessionUnavailable(root.lastError)
        return
      }
      root.acceptToken(result)
      root.sessionChecked = true
      root.finishWaiters(root.accessToken, "")
      root.loginSucceeded()
    })
    requestBody = ""
  }

  function clearPkce() {
    pkceVerifier = ""
    pkceChallenge = ""
    oauthState = ""
  }

  function failLogin(reason, listenerAlreadyAnswered) {
    lastError = safeError(reason || "Spotify sign-in failed. Please try again")
    loginBusy = false
    exchangingCode = false
    authTimeout.stop()
    authOpenDelay.stop()
    if (!listenerAlreadyAnswered && callbackListener.running) callbackListener.running = false
    clearPkce()
    sessionUnavailable(lastError)
  }

  function cancelLogin() {
    authTimeout.stop()
    authOpenDelay.stop()
    callbackStopTimer.stop()
    if (callbackListener.running) callbackListener.running = false
    if (pkceGenerator.running) pkceGenerator.running = false
    tokenRequestSerial++
    if (tokenRequest && tokenRequest.abort) tokenRequest.abort()
    tokenRequest = null
    refreshBusy = false
    loginBusy = false
    exchangingCode = false
    callbackHandled = false
    clearPkce()
  }

  Timer {
    id: authOpenDelay
    interval: 120
    onTriggered: root.openAuthorizationPage()
  }

  Timer {
    id: callbackStopTimer
    interval: 250
    onTriggered: if (callbackListener.running) callbackListener.running = false
  }

  Timer {
    id: authTimeout
    interval: 180000
    onTriggered: root.failLogin("Spotify sign-in took too long. Please try again")
  }

  Process {
    id: pkceGenerator
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.handlePkce(line) }
    }
    onExited: function(exitCode) {
      if (root.loginBusy && root.pkceVerifier === "" && exitCode !== 0)
        root.failLogin("Could not start a secure Spotify sign-in. Please try again")
    }
  }

  Process {
    id: callbackListener
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.handleCallbackLine(line) }
    }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: authOpenDelay.restart()
    onExited: function(exitCode) {
      if (root.loginBusy && !root.callbackHandled && !root.exchangingCode)
        root.failLogin(exitCode === 0
          ? "The Spotify sign-in window closed before it finished"
          : "Could not complete Spotify sign-in. Close any other sign-in windows and try again")
    }
  }

  Process {
    id: secretLookup
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.handleSecretLookup(line) }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (!root.lookupHandled) root.handleSecretLookup("")
    }
  }

  Process {
    id: keyringStore
    stdinEnabled: true
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      write(root.keyringWriteToken + "\n")
      root.keyringWriteToken = ""
    }
    onExited: function(exitCode) {
      root.keyringWriteToken = ""
      if (exitCode !== 0)
        root.lastError = "Spotify connected, but the session could not be saved securely. You may need to sign in again after restarting"
      if (root.logoutPendingClear) {
        root.logoutPendingClear = false
        root.clearStoredToken()
      }
    }
  }

  Process {
    id: keyringClear
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }
}

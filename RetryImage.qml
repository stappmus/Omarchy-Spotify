import QtQuick

Image {
  id: root

  // Qt keeps a failed Image in Error until its source changes. Retry remote
  // artwork with a unique query value so a connection failure does not leave
  // a permanent placeholder after the network returns.
  property string requestedSource: ""
  property int retryAttempt: 0
  property int retryLimit: 8
  property int retryBaseDelayMs: 750
  property int retryMaximumDelayMs: 15000
  property string retryToken: ""

  readonly property int retryDelayMs: Math.min(retryMaximumDelayMs,
    retryBaseDelayMs * Math.pow(2, Math.max(0, retryAttempt - 1)))

  function canRetry(url) {
    return /^https?:\/\//i.test(String(url || ""))
  }

  function retryUrl(url, token) {
    var value = String(url || "")
    if (!canRetry(value) || String(token || "") === "") return value

    var fragmentAt = value.indexOf("#")
    var fragment = fragmentAt >= 0 ? value.slice(fragmentAt) : ""
    var base = fragmentAt >= 0 ? value.slice(0, fragmentAt) : value
    return base + (base.indexOf("?") >= 0 ? "&" : "?")
      + "omarchy_art_retry=" + encodeURIComponent(token) + fragment
  }

  source: retryUrl(requestedSource, retryToken)

  onRequestedSourceChanged: {
    retryTimer.stop()
    retryAttempt = 0
    retryToken = ""
  }

  onStatusChanged: {
    if (status === Image.Ready) {
      retryTimer.stop()
      retryAttempt = 0
    } else if (status === Image.Error && canRetry(requestedSource)
        && retryAttempt < retryLimit) {
      retryAttempt++
      retryTimer.restart()
    }
  }

  Timer {
    id: retryTimer
    interval: root.retryDelayMs
    repeat: false
    onTriggered: root.retryToken = String(Date.now()) + "-" + root.retryAttempt
  }
}

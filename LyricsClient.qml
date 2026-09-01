import QtQuick

import "Api.js" as Api

Item {
  id: root

  visible: false
  width: 0
  height: 0

  property var xhrFactory: function() { return new XMLHttpRequest() }
  property var cache: []
  property string requestedKey: ""
  property var requestedSong: null
  property string runningKey: ""
  property string runningMode: ""
  property var result: null
  property string state: "idle"
  property string message: ""
  property var xhr: null

  readonly property var timedLines: result && result.timedLines ? result.timedLines : []
  readonly property string plainLyrics: result ? String(result.plainLyrics || "") : ""
  readonly property bool ready: state === "ready"
  readonly property bool instrumental: state === "instrumental"
  readonly property bool loading: state === "loading"

  function applyResult(payload) {
    result = payload
    state = payload ? String(payload.state || "error") : "idle"
    message = payload ? String(payload.message || "") : ""
  }

  function abortXhr() {
    if (!xhr) return
    try { xhr.abort() } catch (error) {}
    xhr = null
  }

  function fetchSong(song) {
    var key = Api.lyricsCacheKey(song)
    requestedSong = song
    requestedKey = key
    if (!key) {
      applyResult(Api.emptyLyricsResult("idle", "", ""))
      return
    }
    var cached = Api.lruCacheGet(cache, key)
    cache = cached.entries
    if (cached.hit && cached.value) {
      applyResult(cached.value)
      return
    }
    if (runningKey === key && xhr) return
    state = "loading"
    message = "Loading lyrics…"
    result = null
    launch("get")
  }

  function launch(mode) {
    abortXhr()
    if (!requestedSong || requestedKey === "") return
    runningKey = requestedKey
    runningMode = mode === "search" ? "search" : "get"
    var query = Api.lrclibQuery(requestedSong, runningMode !== "search")
    if (!query) {
      applyResult(Api.emptyLyricsResult("notfound", "No lyrics found", "lrclib"))
      return
    }
    var url = Api.appendQuery(Api.safeLrclibUrl(runningMode), query)
    var request = null
    try {
      request = xhrFactory()
      xhr = request
      request.onreadystatechange = function() {
        if (request.readyState !== XMLHttpRequest.DONE || root.xhr !== request)
          return
        root.xhr = null
        root.finish(request.status, request.responseText)
      }
      request.open("GET", url)
      request.setRequestHeader("Accept", "application/json")
      request.setRequestHeader("User-Agent", Api.LYRICS_USER_AGENT)
      request.send()
    } catch (error) {
      xhr = null
      applyResult(Api.emptyLyricsResult("error",
        "Could not reach the lyrics service", "lrclib"))
    }
  }

  function finish(status, raw) {
    var key = runningKey
    var mode = runningMode
    runningKey = ""
    runningMode = ""
    if (key !== requestedKey) {
      if (requestedKey) launch("get")
      return
    }
    var payload = Api.parseJson(raw, null)
    if (status === 429) {
      applyResult(Api.emptyLyricsResult("ratelimited",
        "Lyrics rate limited — try again shortly", "lrclib"))
      return
    }
    if (mode === "get") {
      if (status === 404 || status === 0) {
        launch("search")
        return
      }
      if (status >= 200 && status < 300) {
        var parsed = Api.lyricsResultFromPayload(payload, "lrclib:/api/get")
        if (parsed.state === "ready" || parsed.state === "instrumental") {
          remember(key, parsed)
          applyResult(parsed)
          return
        }
      }
      launch("search")
      return
    }
    var searched = status >= 200 && status < 300
      ? Api.lyricsResultFromSearch(payload, "lrclib:/api/search")
      : Api.emptyLyricsResult("error",
        "Could not reach the lyrics service", "lrclib:/api/search")
    if (searched.state === "ready" || searched.state === "instrumental"
        || searched.state === "notfound")
      remember(key, searched)
    applyResult(searched)
  }

  function remember(key, payload) {
    if (!key || !payload) return
    if (payload.state !== "ready" && payload.state !== "instrumental"
        && payload.state !== "notfound")
      return
    cache = Api.lruCachePut(cache, key, payload, Api.LYRICS_CACHE_LIMIT)
  }
}

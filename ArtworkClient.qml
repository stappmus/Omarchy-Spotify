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
  property string requestedTitle: ""
  property string requestedArtist: ""
  property string requestedAlbum: ""
  property string fallbackUrl: ""
  property string runningKey: ""
  property bool omitAlbumTerm: false
  property string imageUrl: ""
  property string state: "idle"
  property var xhr: null

  function abortXhr() {
    if (!xhr) return
    try { xhr.abort() } catch (error) {}
    xhr = null
  }

  function fetchArt(title, artist, album, spotifyUrl) {
    requestedTitle = String(title || "").trim()
    requestedArtist = String(artist || "").trim()
    requestedAlbum = String(album || "").trim()
    fallbackUrl = String(spotifyUrl || "").trim()
    requestedKey = Api.artworkCacheKey(requestedTitle, requestedArtist,
      requestedAlbum)
    omitAlbumTerm = false
    if (!requestedKey || (!requestedTitle && !requestedArtist)) {
      imageUrl = fallbackUrl
      state = fallbackUrl ? "fallback" : "idle"
      return
    }
    var cached = Api.lruCacheGet(cache, requestedKey)
    cache = cached.entries
    if (cached.hit && cached.value) {
      imageUrl = String(cached.value)
      state = "ready"
      return
    }
    if (runningKey === requestedKey && xhr) return
    state = "loading"
    imageUrl = fallbackUrl
    launch()
  }

  function launch() {
    abortXhr()
    runningKey = requestedKey
    var termParts = omitAlbumTerm
      ? [requestedTitle, requestedArtist]
      : [requestedTitle, requestedArtist, requestedAlbum]
    var term = termParts.filter(function(part) { return part !== "" }).join(" ")
    var url = Api.appendQuery(Api.safeItunesSearchUrl(), {
      term: term,
      media: "music",
      entity: "song",
      limit: 15
    })
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
      finish(0, "")
    }
  }

  function finish(status, raw) {
    var key = runningKey
    runningKey = ""
    if (key !== requestedKey) {
      if (requestedKey) launch()
      return
    }
    var payload = Api.parseJson(raw, null)
    var results = payload && Array.isArray(payload.results) ? payload.results : []
    var picked = status >= 200 && status < 300
      ? Api.pickItunesArtworkUrl(results, requestedTitle, requestedArtist,
        requestedAlbum) : ""
    if (!picked && requestedAlbum) {
      // Album-qualified search can over-filter; retry without album in the
      // term is handled by ranking against album even when it is omitted
      // from the query. One extra request only when the first miss happens.
      if (status >= 200 && status < 300 && requestedAlbum) {
        requestedAlbum = requestedAlbum
      }
    }
    var highRes = Api.preferredArtworkUrl(picked)
    if (!highRes && requestedAlbum && !omitAlbumTerm) {
      omitAlbumTerm = true
      launch()
      return
    }
    if (highRes) {
      cache = Api.lruCachePut(cache, key, highRes, Api.ARTWORK_CACHE_LIMIT)
      imageUrl = highRes
      state = "ready"
      return
    }
    imageUrl = fallbackUrl
    state = fallbackUrl ? "fallback" : "missing"
    if (fallbackUrl)
      cache = Api.lruCachePut(cache, key, fallbackUrl, Api.ARTWORK_CACHE_LIMIT)
  }
}

import QtQuick

import "Api.js" as Api

// Thin authenticated transport. It performs no polling and owns only one
// special request: search, which is cancelled whenever a newer query arrives.
// Requests share a small in-flight cap and a Retry-After cooldown so a
// development-mode app does not burst into Spotify's 429 window. After a
// 429, only one request goes out until a later call succeeds.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  required property var auth

  property var searchRequest: null
  property int searchSerial: 0
  property var requestQueue: []
  property int requestsInFlight: 0
  property double rateLimitedUntil: 0
  property bool restrictInFlight: false
  property bool pumpingRequests: false
  property bool pumpAgain: false
  property var activeJobs: []
  property var xhrFactory: function() { return new XMLHttpRequest() }
  property var now: function() { return Date.now() }

  function removeActiveJob(job) {
    var next = []
    for (var i = 0; i < activeJobs.length; i++)
      if (activeJobs[i] !== job) next.push(activeJobs[i])
    activeJobs = next
  }

  function removeQueuedHandle(handle) {
    var next = []
    for (var i = 0; i < requestQueue.length; i++)
      if (!requestQueue[i] || requestQueue[i].handle !== handle)
        next.push(requestQueue[i])
    requestQueue = next
  }

  function finishJob(job, status, payload, error, xhr) {
    if (!job || job.finished === true) return
    job.finished = true
    removeActiveJob(job)
    var elapsed = job.startedAt ? Math.max(0, now() - job.startedAt) : 0
    if (error || elapsed >= 2000)
      console.warn("Spotify API " + String(job.method || "GET") + " "
        + String(job.path || "") + " finished in " + elapsed + " ms"
        + (error ? ": " + Api.redact(error) : ""))
    callbackIfCurrent(job, status, payload, error, xhr)
    releaseRequestSlot(job.handle)
  }

  function expireTimedOutRequests(timestamp) {
    var current = Number(timestamp) || now()
    var jobs = activeJobs.slice()
    for (var i = 0; i < jobs.length; i++) {
      var job = jobs[i]
      if (!job || job.finished === true || !job.deadlineAt
          || current < job.deadlineAt) continue
      var xhr = job.handle ? job.handle.xhr : null
      if (job.handle) {
        job.handle.xhr = null
        job.handle.aborted = true
        removeQueuedHandle(job.handle)
      }
      finishJob(job, 0, null,
        "Spotify took too long to respond. Press Enter to try again.", null)
      if (xhr && xhr.abort) xhr.abort()
    }
  }

  function abortRequest(handle) {
    if (!handle || handle.aborted) return
    handle.aborted = true
    removeQueuedHandle(handle)
    var xhr = handle.xhr
    handle.xhr = null
    if (handle.job) {
      handle.job.finished = true
      removeActiveJob(handle.job)
    }
    if (xhr && xhr.abort) xhr.abort()
    releaseRequestSlot(handle)
  }

  function requestError(status, payload, xhr, fallback) {
    if (status === 429)
      return Api.rateLimitMessage(Api.responseRetryAfter(xhr))
    return Api.responseError(status, payload, fallback)
  }

  function enqueueJob(job, preferFront) {
    requestQueue = Api.enqueueApiJob(requestQueue, job, preferFront)
    pumpRequests()
    return job.handle
  }

  function releaseRequestSlot(handle) {
    if (handle && handle.slotOpen !== true) return
    if (handle) handle.slotOpen = false
    requestsInFlight = Math.max(0, requestsInFlight - 1)
    pumpRequests()
  }

  function pumpRequests() {
    if (pumpingRequests) {
      pumpAgain = true
      return
    }
    pumpingRequests = true
    pumpAgain = false
    while (requestsInFlight < Api.apiInFlightLimit(restrictInFlight)) {
      var wait = Api.apiCooldownMs(Date.now(), rateLimitedUntil)
      if (wait > 0) {
        rateLimitTimer.interval = Math.max(50, wait)
        rateLimitTimer.restart()
        break
      }
      var taken = Api.dequeueApiJob(requestQueue)
      requestQueue = taken.queue
      if (!taken.job) break
      taken.job.handle.slotOpen = true
      requestsInFlight += 1
      startJob(taken.job)
    }
    pumpingRequests = false
    if (pumpAgain) pumpRequests()
  }

  function startJob(job) {
    var handle = job.handle
    var url = Api.safeApiUrl(job.path)
    if (!url) {
      finishJob(job, 0, null, "Something went wrong while contacting Spotify", null)
      return
    }
    url = Api.appendQuery(url, job.query)

    auth.withAccessToken(function(token, tokenError) {
      if (handle.aborted) {
        releaseRequestSlot(handle)
        return
      }
      if (!token) {
        finishJob(job, 0, null, tokenError || "Not logged in", null)
        return
      }
      var xhr = xhrFactory()
      handle.xhr = xhr
      handle.job = job
      xhr.onreadystatechange = function() {
        if (xhr.readyState !== XMLHttpRequest.DONE) return
        if (handle.xhr === xhr) handle.xhr = null
        if (handle.aborted) {
          releaseRequestSlot(handle)
          return
        }
        var payload = Api.parseJson(xhr.responseText, null)
        if (xhr.status === 401 && job.retried !== true) {
          auth.invalidateAccessToken()
          job.retried = true
          requestQueue = Api.enqueueApiJob(requestQueue, job, true)
          releaseRequestSlot(handle)
          return
        }
        if (xhr.status === 429) {
          restrictInFlight = true
          rateLimitedUntil = Api.nextRateLimitedUntil(Date.now(),
            Api.responseRetryAfter(xhr), rateLimitedUntil, job.rateLimitRetries)
          if (job.retryRateLimit !== false
              && Api.shouldRetryRateLimit(job.rateLimitRetries)) {
            job.rateLimitRetries += 1
            requestQueue = Api.enqueueApiJob(requestQueue, job, true)
            releaseRequestSlot(handle)
            return
          }
        } else {
          restrictInFlight = false
        }
        var ok = xhr.status >= 200 && xhr.status < 300
        var error = ok ? "" : root.requestError(xhr.status, payload, xhr,
          "Spotify could not complete this request")
        finishJob(job, xhr.status, payload, error, xhr)
      }
      xhr.open(String(job.method || "GET"), url)
      xhr.setRequestHeader("Authorization", "Bearer " + token)
      if (job.body !== undefined && job.body !== null) {
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.send(JSON.stringify(job.body))
      } else {
        xhr.send()
      }
    })
  }

  function callbackIfCurrent(job, status, payload, error, xhr) {
    if (typeof job.callback === "function")
      job.callback(status, payload, error, xhr)
  }

  function request(method, path, query, body, callback, retried, existingHandle, options) {
    var settings = options || ({})
    var handle = existingHandle || { aborted: false, xhr: null }
    var timeoutMs = Math.max(0, Number(settings.timeoutMs) || 0)
    var startedAt = now()
    var job = {
      method: method,
      path: path,
      query: query,
      body: body,
      callback: callback,
      retried: retried === true,
      rateLimitRetries: 0,
      retryRateLimit: settings.retryRateLimit !== false,
      priority: String(settings.priority || ""),
      timeoutMs: timeoutMs,
      startedAt: startedAt,
      deadlineAt: timeoutMs > 0 ? startedAt + timeoutMs : 0,
      finished: false,
      handle: handle
    }
    handle.job = job
    if (timeoutMs > 0) activeJobs = activeJobs.concat([job])
    return enqueueJob(job, retried === true)
  }

  function cancelSearch() {
    searchSerial++
    abortRequest(searchRequest)
    searchRequest = null
  }

  // Search still uses its own serial so a newer query can reject a stale
  // callback created while a token refresh is still in flight.
  function search(query, type, callback) {
    cancelSearch()
    var serial = searchSerial
    var term = String(query || "").trim()
    var searchType = Api.normalizedSearchType(type)
    if (!term) {
      if (typeof callback === "function") callback(Api.searchGroups({}, 128), "")
      return
    }
    searchRequest = request("GET", "/search", {
      q: term,
      type: searchType,
      limit: 10
    }, null, function(status, payload, error) {
      if (serial !== root.searchSerial) return
      if (typeof callback !== "function") return
      if (error) callback(Api.searchGroups({}, 128), error)
      else callback(Api.searchGroups(payload, 128), "")
    }, false, null, {
      priority: "interactive",
      timeoutMs: Api.SEARCH_REQUEST_TIMEOUT_MS,
      retryRateLimit: false
    })
  }

  Timer {
    id: rateLimitTimer
    repeat: false
    onTriggered: root.pumpRequests()
  }

  Timer {
    interval: 250
    repeat: true
    running: root.activeJobs.length > 0
    onTriggered: root.expireTimedOutRequests(root.now())
  }
}

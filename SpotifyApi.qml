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

  property var nativeSession: null
  property var searchRequest: null
  property int searchSerial: 0
  property var requestQueue: []
  property int requestsInFlight: 0
  property double rateLimitedUntil: 0
  property bool restrictInFlight: false
  property bool pumpingRequests: false
  property bool cancellingAll: false
  property bool pumpAgain: false
  property var timedJobs: []
  property var diagnostics: []
  property int activeTimeoutMs: 15000
  property var xhrFactory: function() { return new XMLHttpRequest() }
  property var now: function() { return Date.now() }

  function removeTimedJob(job) {
    var next = []
    for (var i = 0; i < timedJobs.length; i++)
      if (timedJobs[i] !== job) next.push(timedJobs[i])
    timedJobs = next
  }

  function removeQueuedHandle(handle) {
    var next = []
    for (var i = 0; i < requestQueue.length; i++)
      if (!requestQueue[i] || requestQueue[i].handle !== handle)
        next.push(requestQueue[i])
    requestQueue = next
  }

  function abortXhr(xhr) {
    if (!xhr || typeof xhr.abort !== "function") return
    try {
      xhr.abort()
    } catch (error) {
      console.warn("Spotify API request abort failed: " + Api.redact(error))
    }
  }

  function markJobFinished(job) {
    if (!job || job.finished === true) return
    job.finished = true
    removeTimedJob(job)
    if (job.handle && job.handle.job === job) job.handle.job = null
    return true
  }

  function deliverJob(job, status, payload, error, xhr) {
    var elapsed = job.queuedAt !== undefined
      ? Math.max(0, now() - job.queuedAt) : 0
    var entry = {
      route: String(job.path || "").split("?")[0].replace(/^https:\/\/api.spotify.com\/v1/, "")
        .replace(/\/(users|artists|albums|tracks|playlists|shows|episodes|audiobooks)\/[^/]+/g, "/$1/:id"),
      method: String(job.method || "GET"), status: status,
      durationMs: elapsed,
      queueMs: Math.max(0, (job.startedAt || now()) - job.queuedAt),
      tokenMs: job.sentAt ? Math.max(0, job.sentAt - job.startedAt) : 0,
      httpMs: job.sentAt ? Math.max(0, now() - job.sentAt) : 0,
      retries: job.rateLimitRetries + (job.retried ? 1 : 0),
      outcome: error ? (status ? "http-error" : "transport-error") : "success"
    }
    diagnostics = diagnostics.concat([entry]).slice(-100)
    releaseRequestSlot(job.handle)
    callbackIfCurrent(job, status, payload, error, xhr)
  }

  function finishJob(job, status, payload, error, xhr) {
    if (markJobFinished(job) !== true) return
    deliverJob(job, status, payload, error, xhr)
  }

  function expireTimedOutRequests(timestamp) {
    var current = Number(timestamp)
    if (!isFinite(current)) current = now()
    var jobs = timedJobs.slice()
    for (var i = 0; i < jobs.length; i++) {
      var job = jobs[i]
      if (!job || job.finished === true) continue
      var deadline = job.deadlineAt || job.activeDeadlineAt
      if (!deadline || current < deadline) continue
      var handle = job.handle
      var xhr = handle ? handle.xhr : null
      var cooldownMs = Api.apiCooldownMs(current, rateLimitedUntil)
      var waitingForCooldown = cooldownMs > 0 && requestQueue.indexOf(job) >= 0
      var error = waitingForCooldown
        ? Api.rateLimitMessage(String(Math.ceil(cooldownMs / 1000)))
        : "Spotify took too long to respond. Try again."
      if (String(job.method || "GET") !== "GET" && job.sentAt)
        error = "Spotify did not confirm this action. Check playback or your collection before retrying."
      if (markJobFinished(job) !== true) continue
      if (handle) {
        handle.xhr = null
        handle.aborted = true
        removeQueuedHandle(handle)
      }
      abortXhr(xhr)
      deliverJob(job, 0, null, error, null)
    }
  }

  function abortRequest(handle) {
    if (!handle || handle.aborted) return
    handle.aborted = true
    removeQueuedHandle(handle)
    var xhr = handle.xhr
    handle.xhr = null
    if (handle.job && handle.job.finished !== true) {
      handle.job.finished = true
      removeTimedJob(handle.job)
    }
    handle.job = null
    abortXhr(xhr)
    releaseRequestSlot(handle)
  }

  function quotaExceeded(payload) {
    return !!payload && !!payload.error
      && payload.error.reason === "QUOTA_EXCEEDED"
  }

  function requestError(status, payload, xhr, fallback) {
    if (status === 429 && quotaExceeded(payload))
      return "This Spotify app has exhausted its developer quota. Check the app configuration or use another authorized client."
    if (status === 429)
      return Api.rateLimitMessage(Api.responseRetryAfter(xhr))
    return Api.responseError(status, payload, fallback)
  }

  function enqueueJob(job) {
    requestQueue = Api.enqueueApiJob(requestQueue, job)
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
    if (cancellingAll) return
    if (pumpingRequests) {
      pumpAgain = true
      return
    }
    pumpingRequests = true
    pumpAgain = false
    while (requestsInFlight < Api.apiInFlightLimit(restrictInFlight)) {
      var wait = Api.apiCooldownMs(now(), rateLimitedUntil)
      if (wait > 0) {
        // Timer.interval is a signed int; recheck longer cooldowns in chunks.
        rateLimitTimer.interval = Math.min(2147483647, Math.max(50, wait))
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
    job.startedAt = now()
    job.activeDeadlineAt = job.startedAt + activeTimeoutMs
    var url = Api.safeApiUrl(job.path)
    if (!url) {
      finishJob(job, 0, null, "Something went wrong while contacting Spotify", null)
      return
    }
    url = Api.appendQuery(url, job.query)

    if (nativeSession) {
      job.sentAt = now()
      job.activeDeadlineAt = job.sentAt + 45000
      handle.xhr = nativeSession.request(job.method, job.path, job.query, job.body,
        function(status, payload, error) {
          if (handle.aborted || job.finished) return
          handle.xhr = null
          if (status === 429) {
            restrictInFlight = true
            rateLimitedUntil = Api.nextRateLimitedUntil(now(), null,
              rateLimitedUntil, job.rateLimitRetries)
          } else if (status >= 200 && status < 300) restrictInFlight = false
          finishJob(job, status, payload, error, null)
        })
      return
    }

    auth.withAccessToken(function(token, tokenError) {
      if (handle.aborted) {
        releaseRequestSlot(handle)
        return
      }
      if (!token) {
        finishJob(job, 0, null, tokenError || "Not logged in", null)
        return
      }
      job.sentAt = now()
      job.activeDeadlineAt = job.sentAt + activeTimeoutMs
      var xhr = null
      try {
        xhr = xhrFactory()
        handle.xhr = xhr
        xhr.onreadystatechange = function() {
          if (xhr.readyState !== XMLHttpRequest.DONE || handle.xhr !== xhr) return
          handle.xhr = null
          if (handle.aborted || job.finished === true) return
          var payload = Api.parseJson(xhr.responseText, null)
          if (xhr.status === 401 && job.retried !== true) {
            auth.invalidateAccessToken()
            job.activeDeadlineAt = 0
            job.retried = true
            requestQueue = Api.enqueueApiJob(requestQueue, job)
            releaseRequestSlot(handle)
            return
          }
          if (xhr.status === 429 && !quotaExceeded(payload)) {
            restrictInFlight = true
            rateLimitedUntil = Api.nextRateLimitedUntil(now(),
              Api.responseRetryAfter(xhr), rateLimitedUntil, job.rateLimitRetries)
            if (job.retryRateLimit !== false
                && Api.shouldRetryRateLimit(job.rateLimitRetries)) {
              job.activeDeadlineAt = 0
              job.rateLimitRetries += 1
              requestQueue = Api.enqueueApiJob(requestQueue, job)
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
      } catch (error) {
        if (handle.xhr === xhr) handle.xhr = null
        if (handle.aborted) {
          releaseRequestSlot(handle)
          return
        }
        finishJob(job, 0, null, "Something went wrong while contacting Spotify", null)
      }
    })
  }

  function callbackIfCurrent(job, status, payload, error, xhr) {
    if (typeof job.callback === "function")
      job.callback(status, payload, error, xhr)
  }

  function request(method, path, query, body, callback, options) {
    var settings = options || ({})
    var handle = { aborted: false, xhr: null, job: null }
    var timeoutMs = Math.max(0, Number(settings.timeoutMs) || 0)
    var queuedAt = now()
    var job = {
      method: method,
      path: path,
      query: query,
      body: body,
      callback: callback,
      retried: false,
      rateLimitRetries: 0,
      retryRateLimit: settings.retryRateLimit !== false,
      priority: String(settings.priority || ""),
      timeoutMs: timeoutMs,
      queuedAt: queuedAt,
      deadlineAt: timeoutMs > 0 ? queuedAt + timeoutMs : 0,
      finished: false,
      handle: handle
    }
    handle.job = job
    timedJobs = timedJobs.concat([job])
    return enqueueJob(job)
  }

  function cancelAll() {
    cancellingAll = true
    var jobs = timedJobs.slice()
    for (var i = 0; i < jobs.length; i++) abortRequest(jobs[i].handle)
    cancelSearch()
    cancellingAll = false
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
    }, {
      priority: "interactive",
      timeoutMs: Api.SEARCH_REQUEST_TIMEOUT_MS,
      retryRateLimit: false
    })
  }

  Timer {
    id: rateLimitTimer
    objectName: "rateLimitTimer"
    repeat: false
    onTriggered: root.pumpRequests()
  }

  Timer {
    interval: 250
    repeat: true
    running: root.timedJobs.length > 0
    onTriggered: root.expireTimedOutRequests(root.now())
  }
}

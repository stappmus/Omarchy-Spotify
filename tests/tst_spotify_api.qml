pragma ComponentBehavior: Bound

import QtQuick
import QtTest

import ".." as Plugin

TestCase {
  id: testCase
  name: "SpotifyApiTransport"

  property var requests: []
  property double clock: 1000
  property int tokenInvalidations: 0
  property string accessToken: "mock-token"
  property string accessTokenError: ""
  property bool failFactory: false
  property bool failOpen: false
  property bool failSend: false

  QtObject {
    id: fakeAuth

    function withAccessToken(callback) {
      callback(testCase.accessToken, testCase.accessTokenError)
    }
    function invalidateAccessToken() { testCase.tokenInvalidations++ }
  }

  Component {
    id: apiComponent

    Plugin.SpotifyApi {
      auth: fakeAuth
      now: function() { return testCase.clock }
      xhrFactory: function() {
        if (testCase.failFactory) throw new Error("factory failed")
        return testCase.newRequest()
      }
    }
  }

  function newRequest() {
    var xhr = {
      readyState: XMLHttpRequest.UNSENT,
      status: 0,
      retryAfter: "1",
      responseText: "",
      url: "",
      method: "",
      aborted: false,
      onreadystatechange: null,
      open: function(method, url) {
        if (testCase.failOpen) throw new Error("open failed")
        this.method = method
        this.url = url
        this.readyState = XMLHttpRequest.OPENED
      },
      setRequestHeader: function() {},
      getResponseHeader: function(name) {
        return String(name).toLowerCase() === "retry-after" ? this.retryAfter : ""
      },
      send: function() {
        if (testCase.failSend) throw new Error("send failed")
      },
      abort: function() { this.aborted = true }
    }
    requests.push(xhr)
    return xhr
  }

  function complete(xhr, status, body) {
    xhr.status = status
    xhr.responseText = body || "{}"
    xhr.readyState = XMLHttpRequest.DONE
    xhr.onreadystatechange()
  }

  function init() {
    requests = []
    clock = 1000
    tokenInvalidations = 0
    accessToken = "mock-token"
    accessTokenError = ""
    failFactory = false
    failOpen = false
    failSend = false
  }

  function test_nativeTransportAvoidsWebTokensAndCancelsObsoleteSearch() {
    var calls = []
    var native = { request: function(method, path, query, body, callback) {
      var request = {method:method, path:path, callback:callback, cancelled:false}
      calls.push(request)
      return {abort:function() { request.cancelled = true }}
    }}
    var api = createTemporaryObject(apiComponent, testCase, {nativeSession:native})
    failFactory = true
    accessTokenError = "There must be no Web API token request"
    var completions = 0
    api.search("old", "track", function() { completions++ })
    api.search("new", "track", function() { completions++ })
    verify(calls[0].cancelled)
    calls[0].callback(200, {tracks:{items:[]}}, "")
    compare(completions, 0)
    calls[1].callback(200, {tracks:{items:[]}}, "")
    compare(completions, 1)
    compare(api.requestsInFlight, 0)
    compare(requests.length, 0)
  }

  function test_nativeRateLimitDelaysFurtherRequestsWithoutRepeatingMutation() {
    var calls = []
    var native = { request: function(method, path, query, body, callback) {
      calls.push(callback)
      return {abort:function() {}}
    }}
    var api = createTemporaryObject(apiComponent, testCase, {nativeSession:native})
    var completions = 0
    api.request("POST", "/me/playlists", null, {name:"test"}, function() { completions++ })
    calls[0](429, null, "Spotify is busy")
    compare(completions, 1)
    verify(api.rateLimitedUntil > clock)
    api.request("GET", "/me/tracks", null, null, function() {})
    compare(calls.length, 1)
    compare(api.requestQueue.length, 1)
  }

  function test_priorityStartsMutationsThenInteractiveReads() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    api.request("GET", "/me", null, null, function() {})
    api.request("GET", "/me/player", null, null, function() {})
    api.request("GET", "/me/albums", null, null, function() {})
    api.request("GET", "/search", null, null, function() {},
      { priority: "interactive" })
    api.request("PUT", "/me/player/play", null, null, function() {})
    compare(requests.length, 2)

    complete(requests[0], 200)
    compare(requests.length, 3)
    compare(requests[2].method, "PUT")

    complete(requests[1], 200)
    compare(requests.length, 4)
    verify(requests[3].url.indexOf("/search") >= 0)
  }

  function test_searchRequestsOnlyTheSelectedType() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var callbacks = 0
    api.search("miles davis", "album", function(groups, error) {
      callbacks++
      compare(error, "")
    })
    compare(requests.length, 1)
    verify(requests[0].url.indexOf("type=album") >= 0)
    verify(requests[0].url.indexOf("artist%2Calbum") < 0)
    complete(requests[0], 200, "{\"albums\":{\"items\":[]}}")
    compare(callbacks, 1)
  }

  function test_searchFallsBackToTracksForAnInvalidType() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    api.search("miles davis", "unknown", function() {})
    compare(requests.length, 1)
    verify(requests[0].url.indexOf("type=track") >= 0)
  }

  function test_searchTimeoutAbortsAndReleasesSlotOnce() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var callbacks = 0
    var error = ""
    api.search("stalled", "track", function(groups, reason) {
      callbacks++
      error = reason
    })
    compare(api.requestsInFlight, 1)
    clock = 9000
    api.expireTimedOutRequests(clock)
    verify(requests[0].aborted)
    verify(error.indexOf("too long") >= 0)
    compare(callbacks, 1)
    compare(api.requestsInFlight, 0)
    compare(api.timedJobs.length, 0)

    complete(requests[0], 0)
    compare(callbacks, 1)
    compare(api.requestsInFlight, 0)
  }

  function test_queuedSearchTimesOutBeforeARequestSlotOpens() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    api.request("GET", "/me", null, null, function() {})
    api.request("GET", "/me/player", null, null, function() {})
    compare(api.requestsInFlight, 2)
    var error = ""
    api.search("queued", "track", function(groups, reason) { error = reason })
    compare(requests.length, 2)
    compare(api.requestQueue.length, 1)
    clock = 9000
    api.expireTimedOutRequests(clock)
    verify(error.indexOf("too long") >= 0)
    compare(api.requestQueue.length, 0)
    compare(api.requestsInFlight, 2)
  }

  function test_searchBlockedByCooldownReportsRemainingWait() {
    var api = createTemporaryObject(apiComponent, testCase)
    api.rateLimitedUntil = 15000
    var errors = []
    api.search("waiting", "track", function(groups, error) { errors.push(error) })
    compare(requests.length, 0)
    clock = 9000
    api.expireTimedOutRequests(clock)
    compare(errors, ["Spotify is busy. Try again in 6 seconds."])
    compare(api.requestQueue.length, 0)
    compare(api.timedJobs.length, 0)
    clock = 15000
    api.pumpRequests()
    compare(requests.length, 0)
    compare(errors.length, 1)
  }

  function test_inFlightSearchStillReportsTimeoutDuringAnotherCooldown() {
    var api = createTemporaryObject(apiComponent, testCase)
    var error = ""
    api.search("sent", "track", function(groups, reason) { error = reason })
    api.rateLimitedUntil = 15000
    clock = 9000
    api.expireTimedOutRequests(clock)
    compare(error, "Spotify took too long to respond. Try again.")
    verify(requests[0].aborted)
  }

  function test_cooldownCanExpireBeforeSearchDeadline() {
    var api = createTemporaryObject(apiComponent, testCase)
    api.rateLimitedUntil = 4000
    var errors = []
    api.search("waiting", "track", function(groups, error) { errors.push(error) })
    clock = 4000
    api.pumpRequests()
    compare(requests.length, 1)
    complete(requests[0], 200, "{\"tracks\":{\"items\":[]}}")
    clock = 9000
    api.expireTimedOutRequests(clock)
    compare(errors, [""])
  }

  function test_cancelledSearchDuringCooldownHasNoStaleError() {
    var api = createTemporaryObject(apiComponent, testCase)
    api.rateLimitedUntil = 15000
    var oldCalls = 0
    var newErrors = []
    api.search("old", "track", function() { oldCalls++ })
    clock = 2000
    api.search("new", "track", function(groups, error) { newErrors.push(error) })
    clock = 9000
    api.expireTimedOutRequests(clock)
    compare(oldCalls, 0)
    compare(newErrors.length, 0)
    clock = 10000
    api.expireTimedOutRequests(clock)
    compare(newErrors, ["Spotify is busy. Try again in 5 seconds."])
    compare(requests.length, 0)
  }

  function test_expiredCooldownDoesNotMislabelQueuedTimeout() {
    var api = createTemporaryObject(apiComponent, testCase)
    api.rateLimitedUntil = 9000
    var error = ""
    api.search("waiting", "track", function(groups, reason) { error = reason })
    clock = 9000
    api.expireTimedOutRequests(clock)
    compare(error, "Spotify took too long to respond. Try again.")
  }

  function test_search429ReturnsWithoutSilentRetry() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var callbacks = 0
    var error = ""
    api.search("busy", "track", function(groups, reason) {
      callbacks++
      error = reason
    })
    complete(requests[0], 429, "{\"error\":{\"message\":\"Too many requests\"}}")
    compare(callbacks, 1)
    verify(error.indexOf("Spotify is busy") >= 0)
    compare(api.requestQueue.length, 0)
    compare(api.requestsInFlight, 0)
    verify(api.rateLimitedUntil > clock)
  }

  function test_default429StillRetriesAfterCooldown() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var callbacks = 0
    api.request("GET", "/me", null, null, function() { callbacks++ })
    complete(requests[0], 429)
    compare(callbacks, 0)
    compare(api.requestQueue.length, 1)
    clock = api.rateLimitedUntil
    api.pumpRequests()
    compare(requests.length, 2)
    complete(requests[1], 200)
    compare(callbacks, 1)
  }

  function test_long429BlocksRetryAndOtherRequestsUntilDeadline() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var callbacks = 0
    api.request("GET", "/me", null, null, function() { callbacks++ })
    requests[0].retryAfter = "120"
    complete(requests[0], 429)
    compare(api.rateLimitedUntil, 121400)
    api.request("GET", "/me/albums", null, null, function() { callbacks++ })

    clock = 31000
    api.pumpRequests()
    compare(requests.length, 1)
    clock = 121399
    api.pumpRequests()
    compare(requests.length, 1)
    compare(callbacks, 0)

    clock = 121400
    api.pumpRequests()
    // The first retry stays serial until a successful response clears 429 mode.
    compare(requests.length, 2)
    complete(requests[1], 200)
    compare(requests.length, 3)
    complete(requests[2], 200)
    compare(callbacks, 2)
    compare(api.requestQueue.length, 0)
  }

  function test_cooldownLongerThanTimerRangeRechecksWithoutDispatchingEarly() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    api.request("GET", "/me", null, null, function() {})
    requests[0].retryAfter = "3000000"
    complete(requests[0], 429)
    var deadline = 3000001400
    compare(api.rateLimitedUntil, deadline)
    var timer = findChild(api, "rateLimitTimer")
    verify(timer)
    compare(timer.interval, 2147483647)
    verify(timer.running)

    clock = 1000 + 2147483647
    timer.triggered()
    compare(requests.length, 1)
    compare(api.rateLimitedUntil, deadline)
    compare(timer.interval, deadline - clock)
    verify(timer.interval > 0)

    clock = deadline - 1
    timer.triggered()
    compare(requests.length, 1)
    clock = deadline
    timer.triggered()
    compare(requests.length, 2)
    complete(requests[1], 200)
  }

  function test_longSearch429DoesNotSilentlyRetry() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var callbacks = 0
    api.search("busy", "track", function(groups, error) {
      callbacks++
      verify(error.indexOf("120 seconds") >= 0)
    })
    requests[0].retryAfter = "120"
    complete(requests[0], 429)
    compare(callbacks, 1)
    compare(api.requestQueue.length, 0)
    clock = 121400
    api.pumpRequests()
    compare(requests.length, 1)
    compare(callbacks, 1)
  }

  function test_401RetriesWithOneTokenInvalidation() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var callbacks = 0
    api.request("GET", "/me", null, null, function() { callbacks++ })
    var firstRequest = requests[0]
    complete(requests[0], 401)
    compare(tokenInvalidations, 1)
    compare(callbacks, 0)
    compare(requests.length, 2)
    complete(firstRequest, 200)
    compare(callbacks, 0)
    complete(requests[1], 200)
    compare(callbacks, 1)
  }

  function test_newSearchCancelsStaleActiveRequest() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var staleCalls = 0
    var currentCalls = 0
    api.search("old", "track", function() { staleCalls++ })
    var oldRequest = requests[0]
    api.search("new", "artist", function() { currentCalls++ })
    verify(oldRequest.aborted)
    compare(requests.length, 2)
    complete(oldRequest, 200, "{\"tracks\":{\"items\":[]}}")
    complete(requests[1], 200, "{\"tracks\":{\"items\":[]}}")
    compare(staleCalls, 0)
    compare(currentCalls, 1)
    compare(api.requestsInFlight, 0)
  }

  function test_cancelledQueuedRequestNeverStarts() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    api.request("GET", "/me", null, null, function() {})
    api.request("GET", "/me/player", null, null, function() {})
    var callbacks = 0
    var handle = api.request("GET", "/search", null, null,
      function() { callbacks++ }, {
        priority: "interactive",
        timeoutMs: 8000
      })
    compare(api.requestQueue.length, 1)
    api.abortRequest(handle)
    compare(api.requestQueue.length, 0)
    complete(requests[0], 200)
    compare(requests.length, 2)
    compare(callbacks, 0)
    compare(api.timedJobs.length, 1)
  }

  function test_timeoutUsesInclusiveDeadlineBoundary() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var callbacks = 0
    api.request("GET", "/search", null, null, function() { callbacks++ },
      { timeoutMs: 1000 })
    api.expireTimedOutRequests(1999)
    compare(callbacks, 0)
    verify(!requests[0].aborted)
    clock = 2000
    api.expireTimedOutRequests(clock)
    compare(callbacks, 1)
    verify(requests[0].aborted)
  }

  function test_queuedRateLimitRetryCanTimeOutDuringCooldown() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var callbacks = 0
    var error = ""
    api.request("GET", "/me", null, null, function(status, payload, reason) {
      callbacks++
      error = reason
    }, { timeoutMs: 2000 })
    complete(requests[0], 429)
    compare(api.requestQueue.length, 1)
    clock = 3000
    api.expireTimedOutRequests(clock)
    compare(callbacks, 1)
    verify(error.indexOf("too long") >= 0)
    compare(api.requestQueue.length, 0)
  }

  function test_invalidUrlAndTokenFailureReleaseSlots() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var errors = 0
    api.request("GET", "https://example.com/not-spotify", null, null,
      function(status, payload, error) { if (error) errors++ })
    compare(errors, 1)
    compare(api.requestsInFlight, 0)

    accessToken = ""
    accessTokenError = "Session unavailable"
    api.request("GET", "/me", null, null,
      function(status, payload, error) { if (error) errors++ })
    compare(errors, 2)
    compare(api.requestsInFlight, 0)
  }

  function test_xhrSetupFailuresReleaseSlots() {
    var modes = ["factory", "open", "send"]
    for (var i = 0; i < modes.length; i++) {
      failFactory = modes[i] === "factory"
      failOpen = modes[i] === "open"
      failSend = modes[i] === "send"
      var api = createTemporaryObject(apiComponent, testCase)
      verify(api)
      var callbacks = 0
      api.request("GET", "/me", null, null,
        function(status, payload, error) {
          callbacks++
          verify(error !== "")
        })
      compare(callbacks, 1)
      compare(api.requestsInFlight, 0)
      api.destroy()
    }
  }

  function test_backgroundWatchdogReleasesSlots() {
    var api = createTemporaryObject(apiComponent, testCase)
    var calls = 0
    api.request("GET", "/me", null, null, function() { calls++ })
    api.request("GET", "/me/player", null, null, function() { calls++ })
    clock = 16000
    api.expireTimedOutRequests(clock)
    compare(calls, 2)
    compare(api.requestsInFlight, 0)
    verify(requests[0].aborted)
    complete(requests[0], 200)
    compare(calls, 2)
  }

  function test_backgroundCooldownDoesNotConsumeActiveTimeout() {
    var api = createTemporaryObject(apiComponent, testCase)
    api.rateLimitedUntil = 121000
    var calls = 0
    api.request("GET", "/me", null, null, function() { calls++ })
    clock = 120000
    api.expireTimedOutRequests(clock)
    compare(calls, 0)
    compare(requests.length, 0)
    clock = 121000
    api.pumpRequests()
    compare(requests.length, 1)
    api.expireTimedOutRequests(clock)
    compare(calls, 0)
    complete(requests[0], 200)
    compare(calls, 1)
  }

  function test_quotaExceededDoesNotRetryOrInventCooldown() {
    var api = createTemporaryObject(apiComponent, testCase)
    var error = ""
    api.request("GET", "/search?q=private-query", null, null,
      function(status, payload, reason) { error = reason })
    complete(requests[0], 429, '{"error":{"reason":"QUOTA_EXCEEDED"}}')
    verify(error.indexOf("developer quota") >= 0)
    compare(api.rateLimitedUntil, 0)
    compare(api.requestQueue.length, 0)
    compare(api.diagnostics[0].route, "/search")
    verify(JSON.stringify(api.diagnostics).indexOf("private-query") < 0)
  }
}

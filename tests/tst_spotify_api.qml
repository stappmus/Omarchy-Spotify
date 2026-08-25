import QtQuick
import QtTest

import ".." as Plugin

TestCase {
  id: testCase
  name: "SpotifyApiTransport"

  property var requests: []
  property double clock: 1000
  property int tokenInvalidations: 0

  QtObject {
    id: fakeAuth

    function withAccessToken(callback) { callback("mock-token", "") }
    function invalidateAccessToken() { testCase.tokenInvalidations++ }
  }

  Component {
    id: apiComponent

    Plugin.SpotifyApi {
      auth: fakeAuth
      now: function() { return testCase.clock }
      xhrFactory: function() { return testCase.newRequest() }
    }
  }

  function newRequest() {
    var xhr = {
      readyState: XMLHttpRequest.UNSENT,
      status: 0,
      responseText: "",
      url: "",
      method: "",
      aborted: false,
      onreadystatechange: null,
      open: function(method, url) {
        this.method = method
        this.url = url
        this.readyState = XMLHttpRequest.OPENED
      },
      setRequestHeader: function() {},
      getResponseHeader: function(name) {
        return String(name).toLowerCase() === "retry-after" ? "10" : ""
      },
      send: function() {},
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
  }

  function test_searchRequestsOnlySelectedType() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var called = 0
    api.search("miles davis", "album", function(groups, error) {
      called++
      compare(error, "")
      verify(groups.album !== undefined)
    })
    compare(requests.length, 1)
    verify(requests[0].url.indexOf("type=album") >= 0)
    verify(requests[0].url.indexOf("artist%2Calbum") < 0)
    complete(requests[0], 200, "{\"albums\":{\"items\":[]}}")
    compare(called, 1)
    compare(api.requestsInFlight, 0)
  }

  function test_searchTimeoutAbortsAndReleasesSlot() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var error = ""
    api.search("stalled", "track", function(groups, reason) { error = reason })
    compare(api.requestsInFlight, 1)
    api.expireTimedOutRequests(9000)
    verify(requests[0].aborted)
    verify(error.indexOf("too long") >= 0)
    compare(api.requestsInFlight, 0)
    compare(api.activeJobs.length, 0)
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

  function test_newSearchCancelsStaleCallback() {
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
    complete(requests[1], 200, "{\"artists\":{\"items\":[]}}")
    compare(staleCalls, 0)
    compare(currentCalls, 1)
  }
}

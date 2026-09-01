import QtQuick
import QtTest

import "../Api.js" as Api

TestCase {
  name: "BuiltInLyricsAndArtwork"

  function test_parseLrc_basicTimestampsAndOffset() {
    var lines = Api.parseLrc(
      "[00:12.00]First line\n[00:15.50]Second line\n[01:02.123]Third line")
    compare(lines.length, 3)
    compare(lines[0].timeMs, 12000)
    compare(lines[0].text, "First line")
    compare(lines[1].timeMs, 15500)
    compare(lines[2].timeMs, 62123)

    var offset = Api.parseLrc(
      "[offset: 500]\n[00:10.00]Hello\n[offset: -250]\n[00:20.00]World")
    compare(offset[0].timeMs, 10000 - 250)
    compare(offset[1].timeMs, 20000 - 250)

    var clamped = Api.parseLrc("[offset: -5000]\n[00:01.00]Early")
    compare(clamped[0].timeMs, 0)
  }

  function test_parseLrc_skipsMetadataMultiStampAndSorts() {
    var lines = Api.parseLrc(
      "[ar:Artist]\n[ti:Title]\n[00:01.00]Keep me\n\n[al:Album]\n[00:02.00]And me")
    compare(lines[0].text, "Keep me")
    compare(lines[1].text, "And me")

    var shared = Api.parseLrc("[00:01.00][00:05.00]Shared")
    compare(shared.length, 2)
    compare(shared[0].timeMs, 1000)
    compare(shared[1].timeMs, 5000)
    compare(shared[0].text, "Shared")

    var ordered = Api.parseLrc("[00:30.00]Later\n[00:10.00]Earlier")
    compare(ordered[0].text, "Earlier")
    compare(ordered[1].text, "Later")

    compare(Api.parseLrc("").length, 0)
    compare(Api.parseLrc("   ").length, 0)
    compare(Api.parseLrc(null).length, 0)
  }

  function test_lyricsSyncPosition_leadsWhilePlaying() {
    compare(Api.lyricsSyncPositionMs(10, false), 10000)
    compare(Api.lyricsSyncPositionMs(10, true), 10000 + Api.LYRICS_PLAYHEAD_LEAD_MS)
    compare(Api.lyricsSyncPositionMs(-1, true), Api.LYRICS_PLAYHEAD_LEAD_MS)
  }

  function test_currentLineIndex_edges() {
    var lines = [
      { timeMs: 1000, text: "a" },
      { timeMs: 2000, text: "b" },
      { timeMs: 3000, text: "c" }
    ]
    compare(Api.currentLineIndex([], 500), -1)
    compare(Api.currentLineIndex(lines, 0), -1)
    compare(Api.currentLineIndex(lines, 999), -1)
    compare(Api.currentLineIndex(lines, 1000), 0)
    compare(Api.currentLineIndex(lines, 1500), 0)
    compare(Api.currentLineIndex(lines, 2000), 1)
    compare(Api.currentLineIndex(lines, 9999), 2)
  }

  function test_lyricsResult_rejectsDegeneratePlainKeepsTimed() {
    var blob = "Deserted throne Radioactive Hum is gone Cold alone Lifeless time Lifelong crime."
    verify(blob.length >= 80)
    verify(Api.isDegeneratePlain(blob))
    verify(!Api.isDegeneratePlain("Line one\nLine two"))

    var rejected = Api.lyricsResultFromPayload({
      plainLyrics: blob, syncedLyrics: null, instrumental: false
    }, "test")
    compare(rejected.state, "notfound")
    compare(rejected.plainLyrics, "")
    compare(rejected.timedLines.length, 0)

    var kept = Api.lyricsResultFromPayload({
      plainLyrics: "Deserted throne\nRadioactive\nHum is gone",
      syncedLyrics: null,
      instrumental: false
    }, "test")
    compare(kept.state, "ready")
    verify(kept.plainLyrics.indexOf("\n") >= 0)

    var timed = Api.lyricsResultFromPayload({
      plainLyrics: "x".repeat(100),
      syncedLyrics: "[00:01.00]First\n[00:02.00]Second",
      instrumental: false
    }, "test")
    compare(timed.state, "ready")
    compare(timed.timedLines.length, 2)
    compare(timed.timedLines[0].text, "First")

    var crlf = Api.lyricsResultFromPayload({
      plainLyrics: "Line one\r\nLine two\rLine three",
      syncedLyrics: null,
      instrumental: false
    }, "test")
    compare(crlf.plainLyrics, "Line one\nLine two\nLine three")

    var instrumental = Api.lyricsResultFromPayload({
      instrumental: true, plainLyrics: "", syncedLyrics: ""
    }, "test")
    compare(instrumental.state, "instrumental")
    verify(instrumental.isInstrumental)
  }

  function test_artworkRanking_prefersAlbumAndRewritesSize() {
    compare(Api.foldArtworkText("Café!"), "cafe")
    compare(Api.foldArtworkText("Hello-World"), "hello world")

    var base = "https://is1-ssl.mzstatic.com/image/thumb/Music/x/y/z/100x100bb.jpg"
    verify(Api.rewriteArtworkSize(base, "1200x1200bb").indexOf("1200x1200bb.jpg") >= 0)
    verify(Api.artworkHostAllowed(base, true))
    verify(!Api.artworkHostAllowed("https://cdn.example.com/100x100bb.jpg", true))
    verify(Api.artworkHostAllowed("https://itunes.apple.com/search", false))
    verify(!Api.artworkHostAllowed("https://itunes.apple.com/search", true))

    var title = Api.foldArtworkText("Song")
    var artist = Api.foldArtworkText("Band")
    var album = Api.foldArtworkText("The Album")
    var exact = Api.scoreItunesResult({
      trackName: "Song", artistName: "Band", collectionName: "The Album"
    }, title, artist, album)
    var single = Api.scoreItunesResult({
      trackName: "Song", artistName: "Band", collectionName: "Song - Single"
    }, title, artist, album)
    verify(exact > single)

    var picked = Api.pickItunesArtworkUrl([
      {
        trackName: "Forced Entry",
        artistName: "Leprous",
        collectionName: "Forced Entry - Single",
        artworkUrl100: "https://is1-ssl.mzstatic.com/image/thumb/Music/a/100x100bb.jpg"
      },
      {
        trackName: "Forced Entry",
        artistName: "Leprous",
        collectionName: "Bilateral",
        artworkUrl100: "https://is1-ssl.mzstatic.com/image/thumb/Music/b/100x100bb.jpg"
      }
    ], "Forced Entry", "Leprous", "Bilateral")
    verify(picked.indexOf("/Music/b/") >= 0)
    compare(Api.pickItunesArtworkUrl([
      {
        trackName: "Song",
        artistName: "Band",
        collectionName: "Album",
        artworkUrl100: "https://cdn.example.com/100x100bb.jpg"
      }
    ], "Song", "Band", "Album"), "")
  }

  function test_artworkLru_holdsTenMostRecentAndMovesHitsToFront() {
    var cache = []
    for (var i = 0; i < 12; i++)
      cache = Api.lruCachePut(cache, "k" + i, "url" + i, Api.ARTWORK_CACHE_LIMIT)
    compare(cache.length, 10)
    compare(cache[0].key, "k11")
    compare(cache[9].key, "k2")

    var hit = Api.lruCacheGet(cache, "k5")
    verify(hit.hit)
    compare(hit.value, "url5")
    compare(hit.entries[0].key, "k5")
    compare(hit.entries.length, 10)

    var miss = Api.lruCacheGet(cache, "k0")
    verify(!miss.hit)

    cache = Api.lruCachePut(hit.entries, "k5", "url5-updated", 10)
    compare(cache[0].value, "url5-updated")
    compare(cache.length, 10)
  }
}

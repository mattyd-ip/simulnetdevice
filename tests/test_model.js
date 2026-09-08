// Plain-node tests for Model.js's pure functions. No framework, no deps --
// run with `node tests/test_model.js` or `make test`.

var assert = require("assert")
var M = require("../Model.js")

var passed = 0
var failed = 0

function test(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    failed++
    console.error("FAIL: " + name)
    console.error("  " + (e && e.message ? e.message : e))
  }
}

// ---- parseKeyValue ----

test("parseKeyValue splits tab-separated lines", function() {
  var out = M.parseKeyValue("state\t100 (connected)\niface\teth0\n")
  assert.strictEqual(out.state, "100 (connected)")
  assert.strictEqual(out.iface, "eth0")
})

test("parseKeyValue ignores lines with no tab and blank lines", function() {
  var out = M.parseKeyValue("no-tab-here\n\nkey\tvalue")
  assert.deepStrictEqual(out, { key: "value" })
})

// ---- linkState / statusText ----

test("linkState: no adapter", function() {
  assert.strictEqual(M.linkState({ state: "no-device" }), "no-device")
})

test("linkState: cable unplugged", function() {
  assert.strictEqual(M.linkState({ carrier: "0" }), "no-cable")
})

test("linkState: cable in but not yet connected", function() {
  assert.strictEqual(M.linkState({ carrier: "1", nmstate: "40 (ip-config)" }), "connecting")
})

test("linkState: connected", function() {
  assert.strictEqual(M.linkState({ carrier: "1", nmstate: "100 (connected)" }), "connected")
})

test("statusText maps every linkState value", function() {
  assert.strictEqual(M.statusText("no-device"), "No Ethernet adapter")
  assert.strictEqual(M.statusText("no-cable"), "No cable connected")
  assert.strictEqual(M.statusText("connecting"), "Cable connected")
  assert.strictEqual(M.statusText("connected"), "Connected")
})

// ---- formatSpeed ----

test("formatSpeed: Mbit/s under 1000", function() {
  assert.strictEqual(M.formatSpeed("100"), "100 Mbit/s")
})

test("formatSpeed: whole Gbit/s", function() {
  assert.strictEqual(M.formatSpeed("1000"), "1 Gbit/s")
})

test("formatSpeed: fractional Gbit/s", function() {
  assert.strictEqual(M.formatSpeed("2500"), "2.5 Gbit/s")
})

test("formatSpeed: invalid/negative yields empty string", function() {
  assert.strictEqual(M.formatSpeed("-1"), "")
  assert.strictEqual(M.formatSpeed("not-a-number"), "")
})

// ---- static IPv4 form ----

test("isManualMethod", function() {
  assert.strictEqual(M.isManualMethod("manual"), true)
  assert.strictEqual(M.isManualMethod("auto"), false)
  assert.strictEqual(M.isManualMethod(undefined), false)
})

test("staticFormDefaults: manual profile reads cfg_* fields", function() {
  var out = M.staticFormDefaults({
    method: "manual",
    cfg_address: "10.0.0.5/24,fe80::1/64",
    cfg_gateway: "10.0.0.1",
    cfg_dns: "1.1.1.1,8.8.8.8"
  })
  assert.deepStrictEqual(out, { address: "10.0.0.5/24", gateway: "10.0.0.1", dns: "1.1.1.1,8.8.8.8" })
})

test("staticFormDefaults: auto profile seeds from the live DHCP lease", function() {
  var out = M.staticFormDefaults({ method: "auto", ip: "192.168.1.20", prefix: "24", gateway: "192.168.1.1" })
  assert.deepStrictEqual(out, { address: "192.168.1.20/24", gateway: "192.168.1.1", dns: "" })
})

test("isValidCidr / isValidIpv4", function() {
  assert.strictEqual(M.isValidCidr("192.168.1.1/24"), true)
  assert.strictEqual(M.isValidCidr("192.168.1.1"), false)
  assert.strictEqual(M.isValidIpv4("192.168.1.1"), true)
  assert.strictEqual(M.isValidIpv4("192.168.1.1/24"), false)
})

test("canApplyStatic: address required, gateway optional but validated", function() {
  assert.strictEqual(M.canApplyStatic({ address: "10.0.0.5/24" }), true)
  assert.strictEqual(M.canApplyStatic({ address: "10.0.0.5/24", gateway: "10.0.0.1" }), true)
  assert.strictEqual(M.canApplyStatic({ address: "10.0.0.5/24", gateway: "not-an-ip" }), false)
  assert.strictEqual(M.canApplyStatic({ address: "" }), false)
})

test("normalizeDns: collapses whitespace/comma separators", function() {
  assert.strictEqual(M.normalizeDns("1.1.1.1, 8.8.8.8   9.9.9.9"), "1.1.1.1,8.8.8.8,9.9.9.9")
  assert.strictEqual(M.normalizeDns("  "), "")
})

// ---- Wi-Fi state ----

test("wifiLinkState", function() {
  assert.strictEqual(M.wifiLinkState({ state: "no-device" }, true), "no-device")
  assert.strictEqual(M.wifiLinkState({}, false), "disabled")
  assert.strictEqual(M.wifiLinkState({ nmstate: "100 (connected)" }, true), "connected")
  assert.strictEqual(M.wifiLinkState({ nmstate: "30 (disconnected)" }, true), "disconnected")
})

test("bandLabel", function() {
  assert.strictEqual(M.bandLabel("auto"), "Auto")
  assert.strictEqual(M.bandLabel(""), "Auto")
  assert.strictEqual(M.bandLabel("5"), "5 GHz")
})

// ---- throughputState ----

test("throughputState: first sample for an interface resets rather than spiking", function() {
  var out = M.throughputState(null, { iface: "eth0", rx_bytes: "1000", tx_bytes: "500" }, 1000)
  assert.strictEqual(out.downloadRate, 0)
  assert.strictEqual(out.uploadRate, 0)
  assert.strictEqual(out.prevRxBytes, 1000)
})

test("throughputState: computes rate as bytes over elapsed seconds", function() {
  var first = M.throughputState(null, { iface: "eth0", rx_bytes: "1000", tx_bytes: "500" }, 1000)
  var second = M.throughputState(first, { iface: "eth0", rx_bytes: "3000", tx_bytes: "1500" }, 1002)
  assert.strictEqual(second.downloadRate, 1000) // (3000-1000)/2s
  assert.strictEqual(second.uploadRate, 500)
})

test("throughputState: switching interfaces resets instead of computing a bogus delta", function() {
  var first = M.throughputState(null, { iface: "eth0", rx_bytes: "1000", tx_bytes: "500" }, 1000)
  var switched = M.throughputState(first, { iface: "wlan0", rx_bytes: "50", tx_bytes: "10" }, 1002)
  assert.strictEqual(switched.downloadRate, 0)
  assert.strictEqual(switched.prevIface, "wlan0")
})

test("throughputState: never reports a negative rate on counter reset", function() {
  var first = M.throughputState(null, { iface: "eth0", rx_bytes: "5000", tx_bytes: "5000" }, 1000)
  var dropped = M.throughputState(first, { iface: "eth0", rx_bytes: "10", tx_bytes: "10" }, 1001)
  assert.strictEqual(dropped.downloadRate, 0)
  assert.strictEqual(dropped.uploadRate, 0)
})

// ---- ping / sustained-loss recovery trigger ----

test("pingLatencyState: appends samples and caps the window, dropping the oldest", function() {
  var state = null
  state = M.pingLatencyState(state, { internet_ping_ms: "10" }, 3, 3)
  state = M.pingLatencyState(state, { internet_ping_ms: "20" }, 3, 3)
  state = M.pingLatencyState(state, { internet_ping_ms: "bad" }, 3, 3) // a failed ping records null
  assert.deepStrictEqual(state.internetPingSamples, [10, 20, null])
  state = M.pingLatencyState(state, { internet_ping_ms: "30" }, 3, 3) // window is full; oldest (10) drops
  assert.deepStrictEqual(state.internetPingSamples, [20, null, 30])
})

test("pingLatencyState: averages ignore lost samples; loss% counts them", function() {
  var state = null
  state = M.pingLatencyState(state, { internet_ping_ms: "20" }, 3, 3)
  state = M.pingLatencyState(state, { internet_ping_ms: "bad" }, 3, 3)
  state = M.pingLatencyState(state, { internet_ping_ms: "30" }, 3, 3)
  assert.strictEqual(state.internetPingLatency, 25) // (20+30)/2, null excluded
  assert.strictEqual(state.internetPingPacketLoss, 33) // 1 of 3 lost
})

test("pingPacketLossPercent", function() {
  assert.strictEqual(M.pingPacketLossPercent([]), 0)
  assert.strictEqual(M.pingPacketLossPercent([1, null, null, null]), 75)
})

test("isSustainedPingLoss: only the most recent `threshold` samples matter", function() {
  // Lost 3 in a row, then one success -- not sustained anymore.
  assert.strictEqual(M.isSustainedPingLoss([null, null, null, 12], 3), false)
  // Most recent 3 are all lost, regardless of older history.
  assert.strictEqual(M.isSustainedPingLoss([12, null, null, null], 3), true)
})

test("isSustainedPingLoss: fewer samples than the threshold is never sustained", function() {
  assert.strictEqual(M.isSustainedPingLoss([null, null], 5), false)
})

// ---- formatting ----

test("formatBytes: unit boundaries", function() {
  assert.strictEqual(M.formatBytes(500), "500 B")
  assert.strictEqual(M.formatBytes(2048), "2.0 KB")
  assert.strictEqual(M.formatBytes(5 * 1024 * 1024), "5.0 MB")
  assert.strictEqual(M.formatBytes(2 * 1024 * 1024 * 1024), "2.00 GB")
})

test("formatPingLatency", function() {
  assert.strictEqual(M.formatPingLatency(5, false), "--")
  assert.strictEqual(M.formatPingLatency(-1, true), "Timeout")
  assert.strictEqual(M.formatPingLatency(5.4, true), "5.4 ms")
  assert.strictEqual(M.formatPingLatency(42.6, true), "43 ms")
})

test("formatPacketLoss", function() {
  assert.strictEqual(M.formatPacketLoss(0, false), "--")
  assert.strictEqual(M.formatPacketLoss(0, true), "0%")
  assert.strictEqual(M.formatPacketLoss(37, true), "37%")
})

// ---- route-metric primary/secondary ----

test("isPrimary: lower metric wins", function() {
  assert.strictEqual(M.isPrimary(100, 600), true)
  assert.strictEqual(M.isPrimary(600, 100), false)
})

test("isPrimary: an undefined sibling metric means \"primary by default\"", function() {
  // Panel.qml relies on this exact behavior when the sibling isn't connected.
  assert.strictEqual(M.isPrimary(100, undefined), true)
})

test("isPrimary: an own metric that isn't finite is never primary", function() {
  assert.strictEqual(M.isPrimary(undefined, 600), false)
})

// ---- Wi-Fi scan list ----

test("sortWifiRows: connected first, then known, then by signal", function() {
  var rows = [
    { connected: false, known: true, signal: 40 },
    { connected: false, known: false, signal: 90 },
    { connected: true, known: true, signal: 10 }
  ]
  var sorted = M.sortWifiRows(rows)
  assert.deepStrictEqual(sorted.map(function(r) { return r.signal }), [10, 40, 90])
})

test("requiresCredentials: open and OWE networks don't need one", function() {
  assert.strictEqual(M.requiresCredentials("open", "open", "owe"), false)
  assert.strictEqual(M.requiresCredentials("owe", "open", "owe"), false)
  assert.strictEqual(M.requiresCredentials("wpa2-psk", "open", "owe"), true)
})

test("canForgetNetwork: only a known, currently-disconnected network", function() {
  assert.strictEqual(M.canForgetNetwork({ known: true, connected: false }), true)
  assert.strictEqual(M.canForgetNetwork({ known: true, connected: true }), false)
  assert.strictEqual(M.canForgetNetwork({ known: false, connected: false }), false)
})

// ---- static-IP profiles ----

test("validateProfileName: non-empty, capped at 40 chars", function() {
  assert.strictEqual(M.validateProfileName("Office LAN"), true)
  assert.strictEqual(M.validateProfileName("   "), false)
  assert.strictEqual(M.validateProfileName(new Array(42).join("x")), false)
})

test("profileSummary", function() {
  assert.strictEqual(M.profileSummary({}), "No address set")
  assert.strictEqual(M.profileSummary({ address: "10.0.0.5/24" }), "10.0.0.5/24")
  assert.strictEqual(M.profileSummary({ address: "10.0.0.5/24", gateway: "10.0.0.1" }), "10.0.0.5/24 → 10.0.0.1")
})

test("loadProfiles: missing/corrupt file yields an empty list, not a throw", function() {
  assert.deepStrictEqual(M.loadProfiles(""), [])
  assert.deepStrictEqual(M.loadProfiles("not json"), [])
  assert.deepStrictEqual(M.loadProfiles("{}"), [])
})

test("loadProfiles: drops entries without a name", function() {
  var out = M.loadProfiles(JSON.stringify([{ name: "ok" }, { address: "no name" }]))
  assert.deepStrictEqual(out, [{ name: "ok" }])
})

test("serializeProfiles round-trips through loadProfiles", function() {
  var profiles = [{ name: "Office", address: "10.0.0.5/24" }]
  assert.deepStrictEqual(M.loadProfiles(M.serializeProfiles(profiles)), profiles)
})

console.log(passed + " passed, " + failed + " failed")
process.exit(failed === 0 ? 0 : 1)

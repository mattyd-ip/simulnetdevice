// Pure helpers for the Ethernet plugin. No QML/Quickshell imports here so
// this stays runnable/testable under plain Node.

function parseKeyValue(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line) continue
    var idx = line.indexOf("\t")
    if (idx === -1) continue
    next[line.substring(0, idx)] = line.substring(idx + 1).trim()
  }
  return next
}

// carrier/operstate come from /sys, nmstate from `nmcli dev show`. Three
// independent signals because a cable can be plugged in with no active
// NetworkManager connection (autoconnect off, profile misconfigured, etc.),
// and that is a meaningfully different state from "unplugged".
function linkState(info) {
  var value = info || {}
  if (value.state === "no-device") return "no-device"
  if (value.carrier !== "1") return "no-cable"
  if (String(value.nmstate || "").indexOf("100") === 0) return "connected"
  return "connecting"
}

function statusText(state) {
  if (state === "no-device") return "No Ethernet adapter"
  if (state === "no-cable") return "No cable connected"
  if (state === "connecting") return "Cable connected"
  return "Connected"
}

function formatSpeed(mbps) {
  var v = parseInt(mbps, 10)
  if (!v || v < 0) return ""
  if (v >= 1000) return (v / 1000).toFixed(v % 1000 === 0 ? 0 : 1) + " Gbit/s"
  return v + " Mbit/s"
}

// nmcli -g on a multi-value field joins entries with commas; take the first
// so a profile with several static addresses still shows one sane value.
function firstValue(csv) {
  var raw = String(csv || "").trim()
  if (raw === "") return ""
  return raw.split(",")[0].trim()
}

function isManualMethod(method) {
  return String(method || "").trim() === "manual"
}

// Seeds the static-IP form. Already-manual profiles show their configured
// values (what will actually get re-applied); DHCP profiles seed from the
// live lease, so "turn static on" defaults to "freeze the address I have
// right now" rather than a blank/wrong prompt.
function staticFormDefaults(info) {
  var value = info || {}
  if (isManualMethod(value.method)) {
    return {
      address: firstValue(value.cfg_address),
      gateway: firstValue(value.cfg_gateway),
      dns: String(value.cfg_dns || "").trim()
    }
  }
  var address = value.ip && value.prefix ? value.ip + "/" + value.prefix : ""
  return {
    address: address,
    gateway: value.gateway || "",
    dns: ""
  }
}

// Very forgiving IPv4 + prefix check -- enough to stop an obviously broken
// value from being handed to nmcli, not a full validator.
function isValidCidr(value) {
  return /^(\d{1,3}\.){3}\d{1,3}\/\d{1,2}$/.test(String(value || "").trim())
}

function isValidIpv4(value) {
  return /^(\d{1,3}\.){3}\d{1,3}$/.test(String(value || "").trim())
}

// Empty gateway/DNS are allowed (a static profile without a gateway is
// valid on an isolated segment); only the address is mandatory.
function canApplyStatic(fields) {
  var value = fields || {}
  if (!isValidCidr(value.address)) return false
  if (value.gateway && !isValidIpv4(value.gateway)) return false
  return true
}

function normalizeDns(text) {
  var raw = String(text || "").trim()
  if (raw === "") return ""
  var parts = raw.split(/[\s,]+/).filter(function(p) { return p !== "" })
  return parts.join(",")
}

// Fixed pair of route metrics used by the "Set as primary" control: the
// primary interface gets the low value, the other gets the high one. Both
// well below NetworkManager's own automatic values (100/600 wired/wifi
// defaults, ~20000+ when it penalizes an interface with unconfirmed
// connectivity), so an explicit choice always wins over the automatic one.
var PRIMARY_METRIC = 100
var SECONDARY_METRIC = 600

// A connection is "primary" once its metric is the lower of the two --
// compare against the actual sibling metric, not a hardcoded threshold,
// since NetworkManager's own penalty can push either well above 600.
function isPrimary(ownMetric, otherMetric) {
  var own = parseInt(ownMetric, 10)
  var other = parseInt(otherMetric, 10)
  if (!isFinite(own)) return false
  if (!isFinite(other)) return true
  return own < other
}

function validateProfileName(name) {
  var trimmed = String(name || "").trim()
  return trimmed.length > 0 && trimmed.length <= 40
}

// One-line summary for a saved profile row, e.g. "192.168.1.50/24 -> 192.168.1.1".
function profileSummary(profile) {
  var value = profile || {}
  var address = value.address || ""
  if (address === "") return "No address set"
  var gateway = value.gateway || ""
  return gateway === "" ? address : address + " → " + gateway
}

if (typeof module !== "undefined") {
  module.exports = {
    parseKeyValue: parseKeyValue,
    linkState: linkState,
    statusText: statusText,
    formatSpeed: formatSpeed,
    firstValue: firstValue,
    isManualMethod: isManualMethod,
    staticFormDefaults: staticFormDefaults,
    isValidCidr: isValidCidr,
    isValidIpv4: isValidIpv4,
    canApplyStatic: canApplyStatic,
    normalizeDns: normalizeDns,
    PRIMARY_METRIC: PRIMARY_METRIC,
    SECONDARY_METRIC: SECONDARY_METRIC,
    isPrimary: isPrimary,
    validateProfileName: validateProfileName,
    profileSummary: profileSummary
  }
}

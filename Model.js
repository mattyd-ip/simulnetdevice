// Pure parsing/formatting/validation helpers shared by the Wi-Fi and
// Ethernet sections, route-metric control, and static-IP profiles. No
// QML/Quickshell imports, so this is runnable under plain Node.

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

// carrier comes from /sys, nmstate from `nmcli dev show`.
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

// Takes the first entry of a comma-joined nmcli -g multi-value field.
function firstValue(csv) {
  var raw = String(csv || "").trim()
  if (raw === "") return ""
  return raw.split(",")[0].trim()
}

function isManualMethod(method) {
  return String(method || "").trim() === "manual"
}

// Seeds the static-IP form: configured values for a manual profile, else
// the live DHCP lease.
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

// Forgiving IPv4 + prefix check, not a full validator.
function isValidCidr(value) {
  return /^(\d{1,3}\.){3}\d{1,3}\/\d{1,2}$/.test(String(value || "").trim())
}

function isValidIpv4(value) {
  return /^(\d{1,3}\.){3}\d{1,3}$/.test(String(value || "").trim())
}

// Only the address is mandatory; gateway/DNS may be empty.
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

function wifiLinkState(info, wifiEnabled) {
  var value = info || {}
  if (value.state === "no-device") return "no-device"
  if (wifiEnabled === false) return "disabled"
  if (String(value.nmstate || "").indexOf("100") === 0) return "connected"
  return "disconnected"
}

function wifiStatusText(state) {
  if (state === "no-device") return "No Wi-Fi adapter"
  if (state === "disabled") return "Wi-Fi is off"
  if (state === "connected") return "Connected"
  return "Not connected"
}

function wifiIconFor(strength) {
  var icons = ["󰤯", "󰤟", "󰤢", "󰤥", "󰤨"]
  var index = Math.max(0, Math.min(4, Math.ceil(strength / 20) - 1))
  return icons[index]
}

// Display text for a band value from `omarchy-network-band` ("auto", "2.4",
// "5", "6").
function bandLabel(band) {
  if (band === "auto" || !band) return "Auto"
  return band + " GHz"
}

// ---- Throughput + ping stats (per interface) ----

function throughputState(previous, next, now) {
  var prev = previous || {}
  var sample = next || {}
  var iface = sample.iface || ""
  var rx = parseFloat(sample.rx_bytes || "0")
  var tx = parseFloat(sample.tx_bytes || "0")
  var previousTime = Number(prev.prevSampleTime || 0)

  if (iface !== (prev.prevIface || "") || previousTime === 0) {
    return { prevIface: iface, prevRxBytes: rx, prevTxBytes: tx, prevSampleTime: now, downloadRate: 0, uploadRate: 0 }
  }

  var downloadRate = Number(prev.downloadRate || 0)
  var uploadRate = Number(prev.uploadRate || 0)
  var dt = now - previousTime
  if (dt > 0) {
    downloadRate = Math.max(0, (rx - Number(prev.prevRxBytes || 0)) / dt)
    uploadRate = Math.max(0, (tx - Number(prev.prevTxBytes || 0)) / dt)
  }

  return { prevIface: iface, prevRxBytes: rx, prevTxBytes: tx, prevSampleTime: now, downloadRate: downloadRate, uploadRate: uploadRate }
}

function pingSampleValue(raw) {
  var value = parseFloat(raw)
  if (!isFinite(value) || value < 0) return null
  return value
}

function appendPingSample(samples, raw, limit) {
  var values = Array.isArray(samples) ? samples.slice() : []
  values.push(pingSampleValue(raw))
  while (values.length > limit) values.shift()
  return values
}

function averagePingLatency(samples, limit) {
  var values = Array.isArray(samples) ? samples : []
  var sampleLimit = Math.max(1, parseInt(limit, 10) || values.length || 1)
  var total = 0
  var count = 0
  for (var i = Math.max(0, values.length - sampleLimit); i < values.length; i++) {
    var value = values[i]
    if (typeof value !== "number" || !isFinite(value) || value < 0) continue
    total += value
    count++
  }
  return count > 0 ? total / count : -1
}

function pingPacketLossPercent(samples) {
  var values = Array.isArray(samples) ? samples : []
  if (values.length === 0) return 0
  var lost = 0
  for (var i = 0; i < values.length; i++) if (values[i] === null) lost++
  return Math.round((lost / values.length) * 100)
}

// True only when the most recent `threshold` samples are all lost.
function isSustainedPingLoss(samples, threshold) {
  var values = Array.isArray(samples) ? samples : []
  var need = Math.max(1, parseInt(threshold, 10) || 1)
  if (values.length < need) return false
  for (var i = values.length - need; i < values.length; i++) {
    if (values[i] !== null) return false
  }
  return true
}

function pingLatencyState(previous, next, limit, averageLimit) {
  var prev = previous || {}
  var sample = next || {}
  var window = Math.max(1, parseInt(limit, 10) || 5)
  var averageWindow = Math.max(1, parseInt(averageLimit, 10) || window)
  var internetSamples = prev.internetPingSamples

  internetSamples = sample.internet_ping_ms === undefined ? [] : appendPingSample(internetSamples, sample.internet_ping_ms, window)

  return {
    internetPingSamples: internetSamples,
    internetPingLatency: averagePingLatency(internetSamples, averageWindow),
    internetPingPacketLoss: pingPacketLossPercent(internetSamples)
  }
}

function formatBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) n = 0
  if (n < 1024) return Math.round(n) + " B"
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB"
  if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + " MB"
  return (n / (1024 * 1024 * 1024)).toFixed(2) + " GB"
}

function formatRate(bytesPerSec) {
  return formatBytes(bytesPerSec) + "/s"
}

function formatPingLatency(ms, hasSamples) {
  if (hasSamples === false) return "--"
  var value = parseFloat(ms)
  if (!isFinite(value) || value < 0) return "Timeout"
  return value.toFixed(value > 0 && value < 10 ? 1 : 0) + " ms"
}

function formatPacketLoss(percent, hasSamples) {
  if (hasSamples === false) return "--"
  var value = parseInt(percent, 10)
  if (!value || value < 0) return "0%"
  return value + "%"
}

// Route metrics used by the "Set as primary" control: the primary
// interface gets the low value, the other gets the high one.
var PRIMARY_METRIC = 100
var SECONDARY_METRIC = 600

// A connection is primary when its metric is lower than the other's.
function isPrimary(ownMetric, otherMetric) {
  var own = parseInt(ownMetric, 10)
  var other = parseInt(otherMetric, 10)
  if (!isFinite(own)) return false
  if (!isFinite(other)) return true
  return own < other
}

// ---- Wi-Fi scanning (nearby networks) ----

// Converts a WifiNetwork into a plain-data row.
function wifiRow(network) {
  if (!network) return null
  return {
    connected: !!network.connected,
    known: !!network.known,
    ssid: network.name || "",
    signal: Math.round((network.signalStrength || 0) * 100),
    security: network.security
  }
}

function sortWifiRows(rows) {
  var nets = Array.isArray(rows) ? rows.slice() : []
  nets.sort(function(a, b) {
    if (a.connected !== b.connected) return a.connected ? -1 : 1
    if (a.known !== b.known) return a.known ? -1 : 1
    return b.signal - a.signal
  })
  return nets
}

function wifiSectionTitle(wifiNetworks, index) {
  var networks = Array.isArray(wifiNetworks) ? wifiNetworks : []
  if (index < 0 || index >= networks.length) return ""
  var net = networks[index]
  if (!net) return ""
  if (net.known && index === 0) return "KNOWN NETWORKS"
  if (!net.known && (index === 0 || (networks[index - 1] && networks[index - 1].known))) return "OTHER NETWORKS"
  return ""
}

// Open and OWE networks require no credentials.
function requiresCredentials(security, openSecurity, oweSecurity) {
  return security !== openSecurity && security !== oweSecurity
}

function canForgetNetwork(network) {
  return !!(network && network.known && !network.connected)
}

function networkFailureReason(reason, needsCredentials, reasons) {
  var r = reasons || {}
  if (needsCredentials && reason === r.NoSecrets) return "Passphrase required"
  if (needsCredentials && reason === r.WifiAuthTimeout) return "Wrong password"
  if (reason === r.WifiNetworkLost) return "Network lost"
  if (reason === r.WifiClientDisconnected) return "Disconnected"
  if (reason === r.WifiClientFailed) return "Connection failed"
  return "Failed to connect"
}

// True when a failed connect looks like a missing/wrong saved PSK.
function shouldRepromptPassphrase(reason, needsCredentials, reasons) {
  var r = reasons || {}
  if (!needsCredentials) return false
  return reason === r.NoSecrets || reason === r.WifiAuthTimeout
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

// A missing/corrupt file yields an empty list rather than throwing.
function loadProfiles(text) {
  var raw = String(text || "").trim()
  if (raw === "") return []
  try {
    var parsed = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed.filter(function(p) { return p && typeof p.name === "string" })
  } catch (e) {
    return []
  }
}

function serializeProfiles(profiles) {
  return JSON.stringify(Array.isArray(profiles) ? profiles : [], null, 2)
}

if (typeof module !== "undefined") {
  module.exports = {
    parseKeyValue: parseKeyValue,
    linkState: linkState,
    statusText: statusText,
    wifiLinkState: wifiLinkState,
    wifiStatusText: wifiStatusText,
    wifiIconFor: wifiIconFor,
    bandLabel: bandLabel,
    formatSpeed: formatSpeed,
    firstValue: firstValue,
    isManualMethod: isManualMethod,
    staticFormDefaults: staticFormDefaults,
    isValidCidr: isValidCidr,
    isValidIpv4: isValidIpv4,
    canApplyStatic: canApplyStatic,
    normalizeDns: normalizeDns,
    throughputState: throughputState,
    pingLatencyState: pingLatencyState,
    pingPacketLossPercent: pingPacketLossPercent,
    isSustainedPingLoss: isSustainedPingLoss,
    formatBytes: formatBytes,
    formatRate: formatRate,
    formatPingLatency: formatPingLatency,
    formatPacketLoss: formatPacketLoss,
    PRIMARY_METRIC: PRIMARY_METRIC,
    SECONDARY_METRIC: SECONDARY_METRIC,
    isPrimary: isPrimary,
    wifiRow: wifiRow,
    sortWifiRows: sortWifiRows,
    wifiSectionTitle: wifiSectionTitle,
    requiresCredentials: requiresCredentials,
    canForgetNetwork: canForgetNetwork,
    networkFailureReason: networkFailureReason,
    shouldRepromptPassphrase: shouldRepromptPassphrase,
    validateProfileName: validateProfileName,
    profileSummary: profileSummary,
    loadProfiles: loadProfiles,
    serializeProfiles: serializeProfiles
  }
}

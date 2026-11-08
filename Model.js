.pragma library

// Nerd Font Material Design glyphs.
var GLYPHS = {
  idle: "󰣳", // nas
  running: "󰓦", // sync
  failed: "󰀨" // alert-circle
}

// Time Machine's own limit before it warns about a missing backup.
var STALE_SECONDS = 10 * 24 * 3600

var STEPS = ["connection", "password", "repository", "schedule"]

function pathFromUrl(url) {
  var s = String(url || "")
  if (s.indexOf("file://") === 0) s = s.substring(7)
  try {
    return decodeURIComponent(s)
  } catch (e) {
    return s
  }
}

function emptyState() {
  return {
    installed: true,
    btrfs: true,
    config: false,
    login: false,
    password: false,
    host: "",
    repository: "",
    subvolumes: "",
    forget: "",
    quotaGb: 0,
    reachable: false,
    initialized: false,
    timerEnabled: false,
    running: false,
    nextRun: 0,
    result: "",
    lastRun: 0,
    lastSuccess: 0,
    size: 0
  }
}

function parseState(raw) {
  var parsed
  try {
    parsed = JSON.parse(String(raw || ""))
  } catch (e) {
    return null
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null
  var state = emptyState()
  for (var key in state) {
    var value = parsed[key]
    if (typeof value === typeof state[key]) state[key] = value
  }
  return state
}

function steps(state) {
  var done = {
    connection: state.config && state.login && state.host !== "" && state.repository !== "",
    password: state.password,
    repository: state.initialized,
    schedule: state.timerEnabled
  }
  return STEPS.map(function (id) {
    return { id: id, done: done[id] }
  })
}

// Everything a backup needs; the schedule is optional.
function ready(state) {
  return steps(state).every(function (step) {
    return step.done || step.id === "schedule"
  })
}

function overQuota(state) {
  return state.quotaGb > 0 && state.size > state.quotaGb * 1e9
}

function phase(state, now) {
  if (!state) return "loading"
  if (!state.installed) return "missing"
  if (!state.btrfs) return "notBtrfs"
  if (state.running) return "running"
  if (!ready(state)) return "setup"
  if (state.result !== "" && state.result !== "success") return "failed"
  if (overQuota(state)) return "overQuota"
  if (state.lastSuccess === 0) return "never"
  if (!state.timerEnabled) return "off"
  if (now - state.lastSuccess > STALE_SECONDS) return "stale"
  return "ok"
}

function glyph(phase) {
  if (phase === "running") return GLYPHS.running
  if (urgent(phase)) return GLYPHS.failed
  return GLYPHS.idle
}

function urgent(phase) {
  return phase === "failed" || phase === "stale" || phase === "overQuota"
}

function dimmed(phase) {
  return phase === "loading" || phase === "missing" || phase === "notBtrfs" || phase === "setup" || phase === "off"
}

// Single pass, so a "%2" or "$&" inside a value stays literal text.
function format(template, values) {
  return String(template).replace(/%(\d)/g, function (match, n) {
    var value = values[Number(n) - 1]
    return value === undefined ? match : String(value)
  })
}

function ago(seconds, now, strings) {
  var elapsed = Math.max(0, now - seconds)
  if (elapsed < 60) return strings.t("ago.now")
  if (elapsed < 3600) return format(strings.tn("ago.minutes", Math.floor(elapsed / 60)), [Math.floor(elapsed / 60)])
  if (elapsed < 2 * 86400) return format(strings.tn("ago.hours", Math.floor(elapsed / 3600)), [Math.floor(elapsed / 3600)])
  return format(strings.tn("ago.days", Math.floor(elapsed / 86400)), [Math.floor(elapsed / 86400)])
}

// Decimal units, like the NAS and Time Machine count them.
function size(bytes) {
  if (bytes >= 1e12) return (bytes / 1e12).toFixed(1) + " TB"
  if (bytes >= 1e9) return Math.round(bytes / 1e9) + " GB"
  return Math.round(bytes / 1e6) + " MB"
}

function heroMeta(state, now, strings) {
  var p = phase(state, now)
  if (p === "loading" || p === "missing" || p === "notBtrfs" || p === "running" || p === "setup" || p === "never")
    return strings.t("phase." + p)
  var last = format(strings.t("last.success"), [ago(state.lastSuccess, now, strings)])
  if (p === "failed" || p === "overQuota") return strings.t("phase." + p) + " · " + last
  return last
}

// Local calendar days, as the hourly check counts them.
function backedUpToday(state, now) {
  return state.lastSuccess > 0 && new Date(state.lastSuccess * 1000).toDateString() === new Date(now * 1000).toDateString()
}

// Whether today's backup is done, about to start, or waits for the office.
function reach(state, now, strings) {
  if (backedUpToday(state, now)) return strings.t("nas.doneToday")
  if (!state.reachable) return strings.t("nas.away")
  return strings.t(state.timerEnabled ? "nas.due" : "nas.reachable")
}

// The hero line, plus why the icon looks the way it does and where today's
// backup stands.
function tooltip(state, now, strings) {
  var p = phase(state, now)
  var lines = [heroMeta(state, now, strings)]
  if (p === "off" || p === "stale") lines.push(strings.t("phase." + p))
  if (state && ready(state) && p !== "running") lines.push(reach(state, now, strings))
  return lines.join("\n")
}

function usage(state, strings) {
  if (state.size === 0) return ""
  if (state.quotaGb === 0) return format(strings.t("usage.noQuota"), [size(state.size)])
  return format(strings.t("usage.quota"), [size(state.size), size(state.quotaGb * 1e9)])
}

function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'"
}

// Interactive steps run in Omarchy's floating terminal, which ends with a
// Done/Failed prompt so the outcome stays readable.
function terminalCommand(scriptPath, args) {
  var words = ["bash", scriptPath].concat(args).map(shellQuote)
  return ["omarchy-launch-floating-terminal-with-presentation", words.join(" ")]
}

// The first non-empty line of what ctl.sh printed is the error worth showing.
function replyError(text) {
  var lines = String(text || "").split("\n").map(function (line) { return line.trim() })
  for (var i = 0; i < lines.length; i++) if (lines[i] !== "") return lines[i]
  return ""
}

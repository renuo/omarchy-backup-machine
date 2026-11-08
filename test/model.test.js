const { describe, it } = require("node:test")
const assert = require("node:assert/strict")
const path = require("node:path")
const { loadModel } = require("./load-model")

const Model = loadModel()

// Values built inside the vm context carry that context's prototypes, which
// deepStrictEqual would reject; compare their JSON shape instead.
const plain = (value) => JSON.parse(JSON.stringify(value))

// Stands in for Commons.Translations, reading the shipped English catalog so a
// renamed or missing key fails here rather than showing up as a raw key.
const catalog = require(path.join(__dirname, "..", "i18n", "en.json"))
const strings = {
  t: (key) => {
    assert.ok(key in catalog, "missing key " + key)
    return catalog[key]
  },
  tn: (key, count) => catalog[key][count === 1 ? "one" : "other"],
}

const NOW = 1762600000
const HOUR = 3600
const DAY = 24 * HOUR

// A laptop at the office, set up, with a backup an hour ago.
function healthy(fields) {
  return Object.assign(plain(Model.emptyState()), {
    config: true,
    login: true,
    password: true,
    host: "nas.example",
    repository: "rclone::smb:laptop_backups/me-delly",
    subvolumes: "/ /home",
    forget: "--keep-hourly 24",
    quotaGb: 2000,
    reachable: true,
    initialized: true,
    timerEnabled: true,
    result: "success",
    lastRun: NOW - HOUR,
    lastSuccess: NOW - HOUR,
    size: 350e9,
  }, fields)
}

describe("pathFromUrl", () => {
  it("strips file:// and decodes", () => {
    assert.equal(Model.pathFromUrl("file:///a/my%20plugin/ctl.sh"), "/a/my plugin/ctl.sh")
  })

  it("passes plain and undecodable paths through", () => {
    assert.equal(Model.pathFromUrl("/a/ctl.sh"), "/a/ctl.sh")
    assert.equal(Model.pathFromUrl("file:///a/%E0%A4%A"), "/a/%E0%A4%A")
    assert.equal(Model.pathFromUrl(undefined), "")
  })
})

describe("parseState", () => {
  it("reads what ctl.sh state prints", () => {
    const state = healthy({ nextRun: NOW + HOUR })
    assert.deepEqual(plain(Model.parseState(JSON.stringify(state))), state)
  })

  it("fills missing fields and drops ones of the wrong type", () => {
    const state = plain(Model.parseState('{"login":"yes","host":"nas"}'))
    assert.equal(state.login, false)
    assert.equal(state.host, "nas")
    assert.equal(state.size, 0)
  })

  it("reads anything that is not an object as no state", () => {
    assert.equal(Model.parseState("oops"), null)
    assert.equal(Model.parseState("[]"), null)
    assert.equal(Model.parseState("null"), null)
    assert.equal(Model.parseState(undefined), null)
  })
})

describe("steps", () => {
  it("lists every step in order, done when set up", () => {
    assert.deepEqual(plain(Model.steps(healthy())), [
      { id: "connection", done: true },
      { id: "password", done: true },
      { id: "repository", done: true },
      { id: "schedule", done: true },
    ])
  })

  it("wants the login, the settings and a host before the connection counts", () => {
    for (const missing of [{ login: false }, { config: false }, { host: "" }, { repository: "" }])
      assert.equal(plain(Model.steps(healthy(missing)))[0].done, false)
  })
})

describe("ready", () => {
  it("needs every step but the schedule", () => {
    assert.equal(Model.ready(healthy({ timerEnabled: false })), true)
    assert.equal(Model.ready(healthy({ password: false })), false)
    assert.equal(Model.ready(healthy({ initialized: false })), false)
  })
})

describe("phase", () => {
  it("is ok after a recent success", () => {
    assert.equal(Model.phase(healthy(), NOW), "ok")
  })

  it("stays ok away from the office", () => {
    assert.equal(Model.phase(healthy({ reachable: false }), NOW), "ok")
  })

  it("waits for the first state", () => {
    assert.equal(Model.phase(null, NOW), "loading")
  })

  it("names what the machine lacks first", () => {
    assert.equal(Model.phase(healthy({ installed: false, btrfs: false }), NOW), "missing")
    assert.equal(Model.phase(healthy({ btrfs: false, running: true }), NOW), "notBtrfs")
  })

  it("shows a running backup even while the setup is incomplete", () => {
    assert.equal(Model.phase(healthy({ running: true, initialized: false }), NOW), "running")
  })

  it("asks for the setup before reporting runs", () => {
    assert.equal(Model.phase(healthy({ login: false, result: "exit-code" }), NOW), "setup")
  })

  it("reports a failed run before the quota", () => {
    assert.equal(Model.phase(healthy({ result: "exit-code", size: 3000e9 }), NOW), "failed")
  })

  it("warns above the quota, and never without one", () => {
    assert.equal(Model.phase(healthy({ size: 2001e9 }), NOW), "overQuota")
    assert.equal(Model.phase(healthy({ size: 2000e9 }), NOW), "ok")
    assert.equal(Model.phase(healthy({ size: 9000e9, quotaGb: 0 }), NOW), "ok")
  })

  it("knows a ready laptop that never backed up", () => {
    assert.equal(Model.phase(healthy({ result: "", lastSuccess: 0 }), NOW), "never")
  })

  it("notices automatic backups are off", () => {
    assert.equal(Model.phase(healthy({ timerEnabled: false }), NOW), "off")
  })

  it("calls the backup stale after ten days without success", () => {
    assert.equal(Model.phase(healthy({ lastSuccess: NOW - 10 * DAY + 1 }), NOW), "ok")
    assert.equal(Model.phase(healthy({ lastSuccess: NOW - 10 * DAY - 1 }), NOW), "stale")
  })
})

describe("glyph, urgent and dimmed", () => {
  it("shows the NAS, spins while running, alerts when something is wrong", () => {
    assert.equal(Model.glyph("ok"), "\u{F08F3}")
    assert.equal(Model.glyph("running"), "\u{F04E6}")
    for (const p of ["failed", "stale", "overQuota"]) assert.equal(Model.glyph(p), "\u{F0028}")
  })

  it("is urgent only when backups stopped working or outgrew the quota", () => {
    assert.deepEqual(["ok", "failed", "stale", "overQuota", "setup"].map(Model.urgent), [false, true, true, true, false])
  })

  it("dims while there is nothing to trust yet", () => {
    assert.deepEqual(["loading", "missing", "notBtrfs", "setup", "off", "ok", "never"].map(Model.dimmed), [true, true, true, true, true, false, false])
  })
})

describe("format", () => {
  it("fills placeholders once and keeps unknown ones", () => {
    assert.equal(Model.format("%1 → %2 %3", ["$&", "%2"]), "$& → %2 %3")
  })
})

describe("ago", () => {
  it("rounds down to the largest unit that fits", () => {
    assert.equal(Model.ago(NOW - 30, NOW, strings), "just now")
    assert.equal(Model.ago(NOW - 60, NOW, strings), "1 minute ago")
    assert.equal(Model.ago(NOW - HOUR, NOW, strings), "1 hour ago")
    assert.equal(Model.ago(NOW - 47 * HOUR, NOW, strings), "47 hours ago")
    assert.equal(Model.ago(NOW - 2 * DAY, NOW, strings), "2 days ago")
    assert.equal(Model.ago(NOW + 100, NOW, strings), "just now")
  })
})

describe("size", () => {
  it("counts in decimal units like the NAS", () => {
    assert.equal(Model.size(1.25e12), "1.3 TB")
    assert.equal(Model.size(350e9), "350 GB")
    assert.equal(Model.size(12e6), "12 MB")
  })
})

describe("usage", () => {
  it("measures the backups against the quota", () => {
    assert.equal(Model.usage(healthy(), strings), "350 GB of 2.0 TB on the NAS")
    assert.equal(Model.usage(healthy({ quotaGb: 0 }), strings), "350 GB on the NAS")
  })

  it("says nothing before the first backup measured anything", () => {
    assert.equal(Model.usage(healthy({ size: 0 }), strings), "")
  })
})

describe("heroMeta", () => {
  it("says when the last backup succeeded", () => {
    assert.equal(Model.heroMeta(healthy(), NOW, strings), "Last backup 1 hour ago")
  })

  it("puts a failure or the quota before the last success", () => {
    assert.equal(Model.heroMeta(healthy({ result: "exit-code" }), NOW, strings), "Last backup failed · Last backup 1 hour ago")
    assert.equal(Model.heroMeta(healthy({ size: 3000e9 }), NOW, strings), "Over the quota · Last backup 1 hour ago")
  })

  it("names the phases that have no last backup to tell", () => {
    assert.equal(Model.heroMeta(null, NOW, strings), "Loading…")
    assert.equal(Model.heroMeta(healthy({ installed: false }), NOW, strings), "Not installed")
    assert.equal(Model.heroMeta(healthy({ btrfs: false }), NOW, strings), "Needs btrfs")
    assert.equal(Model.heroMeta(healthy({ running: true }), NOW, strings), "Backing up…")
    assert.equal(Model.heroMeta(healthy({ password: false }), NOW, strings), "Not set up yet")
    assert.equal(Model.heroMeta(healthy({ lastSuccess: 0, result: "" }), NOW, strings), "No backup yet")
  })
})

describe("tooltip", () => {
  it("adds whether the NAS is in reach", () => {
    assert.equal(Model.tooltip(healthy(), NOW, strings), "Last backup 1 hour ago\nThe NAS is in reach")
    assert.equal(Model.tooltip(healthy({ reachable: false }), NOW, strings), "Last backup 1 hour ago\nThe NAS is out of reach; backups wait for the office")
  })

  it("adds why the widget is dimmed or urgent", () => {
    assert.equal(Model.tooltip(healthy({ timerEnabled: false, reachable: false }), NOW, strings),
      "Last backup 1 hour ago\nAutomatic backups are off\nThe NAS is out of reach; backups wait for the office")
    assert.equal(Model.tooltip(healthy({ lastSuccess: NOW - 11 * DAY }), NOW, strings),
      "Last backup 11 days ago\nNo backup for over 10 days\nThe NAS is in reach")
  })

  it("leaves reachability out while running or not set up", () => {
    assert.equal(Model.tooltip(healthy({ running: true }), NOW, strings), "Backing up…")
    assert.equal(Model.tooltip(healthy({ login: false }), NOW, strings), "Not set up yet")
    assert.equal(Model.tooltip(null, NOW, strings), "Loading…")
  })
})

describe("terminalCommand", () => {
  it("runs the script in Omarchy's floating terminal with every word quoted", () => {
    assert.deepEqual(plain(Model.terminalCommand("/p/ctl.sh", ["connect", "it's"])), [
      "omarchy-launch-floating-terminal-with-presentation",
      "'bash' '/p/ctl.sh' 'connect' 'it'\\''s'",
    ])
  })
})

describe("replyError", () => {
  it("takes the first line with text and nothing from a quiet success", () => {
    assert.equal(Model.replyError("\n Access denied\nmore"), "Access denied")
    assert.equal(Model.replyError(""), "")
    assert.equal(Model.replyError(undefined), "")
  })
})

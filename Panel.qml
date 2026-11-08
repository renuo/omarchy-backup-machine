import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bar button plus popup for the backup of the whole system to the office NAS,
// Time Machine's job on a Mac. The popup walks through the setup one step at
// a time and then offers the backups themselves. nas-backup.service runs as
// root, so its files are root's: every step that changes them runs in
// Omarchy's floating terminal through ctl.sh, with sudo, and the popup steps
// aside for it.
Panel {
  id: root
  moduleName: "renuo.nas-backup"
  ipcTarget: "nas-backup"

  readonly property string ctlPath: Model.pathFromUrl(Qt.resolvedUrl("ctl.sh"))

  property var backupState: null
  property real now: Date.now() / 1000
  property string actionError: ""
  // What the schedule switch was last asked for, until systemd answers.
  property var pendingTimer: null

  readonly property string phase: Model.phase(backupState, now)
  readonly property var steps: backupState ? Model.steps(backupState) : []
  readonly property bool ready: backupState !== null && Model.ready(backupState)
  readonly property bool timerOn: pendingTimer !== null ? pendingTimer : (backupState !== null && backupState.timerEnabled)

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function refresh() {
    now = Date.now() / 1000
    if (stateProc.running) stateProc.again = true
    else stateProc.running = true
  }

  function run(args) {
    actionError = ""
    actionProc.command = ["bash", ctlPath].concat(args)
    actionProc.running = true
  }

  function setTimer(on) {
    if (pendingTimer !== null) return
    pendingTimer = on
    run(["timer", on ? "on" : "off"])
  }

  // The terminal, the editor and other panels open behind a popup that holds
  // the keyboard.
  function inTerminal(args) {
    Quickshell.execDetached(Model.terminalCommand(ctlPath, args))
    close()
  }

  function stepDetail(step) {
    var s = backupState
    if (!step.done) return strings.t("step." + step.id + ".todo")
    if (step.id === "connection") return Model.format(strings.t("step.connection.done"), [s.host, s.repository.replace(/^rclone::smb:/, "")])
    if (step.id === "repository") return Model.format(strings.t("step.repository.done"), [s.subvolumes, s.forget])
    if (step.id === "schedule") return s.nextRun > 0
      ? Model.format(strings.t("step.schedule.done"), [Qt.formatDateTime(new Date(s.nextRun * 1000), "ddd d MMM, HH:mm")])
      : strings.t("step.schedule.unknown")
    return strings.t("step." + step.id + ".done")
  }

  onOpenedChanged: if (opened) {
    actionError = ""
    refresh()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: stateProc
    property bool again: false
    command: ["bash", root.ctlPath, "state"]
    onRunningChanged: if (!running && again) {
      again = false
      running = true
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseState(text)
        if (parsed) root.backupState = parsed
        if (!actionProc.running) root.pendingTimer = null
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.actionError = Model.replyError(text)
        root.refresh()
      }
    }
  }

  // Quick while someone looks or a backup runs; a minute otherwise is plenty
  // for an hourly job.
  Timer {
    interval: root.opened || root.phase === "running" ? 2000 : 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.glyph(root.phase)
    dimmed: Model.dimmed(root.phase)
    active: Model.urgent(root.phase)
    tooltipText: root.opened ? "" : Model.tooltip(root.backupState, root.now, strings)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(680))

    content: PanelKeyCatcher {
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(14)

          PanelHero {
            id: hero
            width: parent.width
            title: strings.t("title")
            meta: Model.heroMeta(root.backupState, root.now, strings)
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: Model.dimmed(root.phase) ? 0.5 : 1.0
            iconComponent: Component {
              Text {
                text: Model.glyph(root.phase)
                textFormat: Text.PlainText
                color: Model.urgent(root.phase) ? root.urgent : hero.foreground
                font.family: hero.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: timerSwitch
                checked: root.timerOn
                busy: root.pendingTimer !== null
                interactive: root.ready || root.timerOn
                foreground: hero.foreground
                onToggled: root.setTimer(!root.timerOn)

                PanelToolTip {
                  visible: timerSwitch.containsMouse
                  text: strings.t(root.timerOn ? "toggle.off" : root.ready ? "toggle.on" : "toggle.notReady")
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Note {
            visible: root.actionError !== ""
            text: root.actionError
            color: root.urgent
          }

          Note {
            visible: root.phase === "missing" || root.phase === "notBtrfs"
            text: visible ? strings.t("hint." + root.phase) : ""
          }

          // ---------- Backups, once there is somewhere to put them ----------
          Column {
            visible: root.ready || root.phase === "running"
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: strings.t("section.backups")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Note {
              text: !root.backupState ? "" : [Model.usage(root.backupState, strings), strings.t(root.backupState.reachable ? "nas.reachable" : "nas.away")]
                .filter(function(line) { return line !== "" }).join("\n")
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Action {
                visible: root.phase !== "running"
                enabled: root.backupState !== null && root.backupState.reachable
                text: strings.t("action.backup")
                iconText: "󰐊" // play
                onClicked: root.run(["backup"])
              }

              Action {
                visible: root.phase === "running"
                text: strings.t("action.stop")
                iconText: "󰓛" // stop
                onClicked: root.run(["stop"])
              }

              Action {
                text: strings.t("action.log")
                onClicked: root.inTerminal(["log"])
              }

              Action {
                text: strings.t("action.snapshots")
                onClicked: root.inTerminal(["snapshots"])
              }

              Action {
                text: strings.t("action.browse")
                onClicked: root.inTerminal(["browse"])
              }

              Action {
                text: strings.t("action.shell")
                onClicked: root.inTerminal(["shell"])
              }
            }
          }

          // ---------- Setup, one step after the other ----------
          PanelSectionHeader {
            visible: root.steps.length > 0
            text: strings.t("section.setup")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.steps

            StepRow {
              required property var modelData
              width: column.width
              step: modelData
            }
          }
        }
      }
    }
  }

  component Note: Text {
    width: parent ? parent.width : 0
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  component Action: Button {
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  component StepRow: Item {
    id: stepRow
    property var step: ({ id: "", done: false })

    implicitHeight: stepColumn.implicitHeight

    Text {
      id: stepIcon
      anchors.left: parent.left
      anchors.top: parent.top
      text: stepRow.step.done ? "󰗠" : "󰝦" // check-circle, circle-outline
      textFormat: Text.PlainText
      color: stepRow.step.done ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
    }

    Column {
      id: stepColumn
      anchors.left: stepIcon.right
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      spacing: Style.space(6)

      Text {
        width: parent.width
        text: strings.t("step." + stepRow.step.id)
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Note {
        text: root.backupState ? root.stepDetail(stepRow.step) : ""
      }

      Flow {
        width: parent.width
        spacing: Style.space(6)

        Action {
          visible: stepRow.step.id === "connection"
          text: strings.t(stepRow.step.done ? "action.reconnect" : "action.connect")
          onClicked: root.inTerminal(["connect"])
        }

        Action {
          visible: stepRow.step.id === "connection" && stepRow.step.done
          text: strings.t("action.edit")
          onClicked: root.inTerminal(["edit", "config"])
        }

        Action {
          visible: stepRow.step.id === "connection" && stepRow.step.done
          text: strings.t("action.excludes")
          onClicked: root.inTerminal(["edit", "excludes"])
        }

        Action {
          visible: stepRow.step.id === "password" && !stepRow.step.done
          text: strings.t("action.createPassword")
          onClicked: root.inTerminal(["password"])
        }

        Action {
          visible: stepRow.step.id === "password" && stepRow.step.done
          text: strings.t("action.copyPassword")
          onClicked: root.inTerminal(["copy-password"])
        }

        Action {
          visible: stepRow.step.id === "repository" && !stepRow.step.done
          enabled: root.backupState !== null && root.backupState.password && root.backupState.login
          text: strings.t("action.init")
          onClicked: root.inTerminal(["init"])
        }

        Action {
          visible: stepRow.step.id === "schedule"
          text: strings.t("action.schedule")
          onClicked: root.inTerminal(["schedule"])
        }
      }
    }
  }
}

const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const MODEL_PATH = path.join(__dirname, "..", "Model.js")

// `.pragma library` is a QML directive, not JavaScript. It is swapped for a
// comment of exactly the same length so coverage offsets still line up with
// the file on disk.
function loadModel() {
  const source = fs.readFileSync(MODEL_PATH, "utf8")
  const pragma = ".pragma library"
  if (!source.startsWith(pragma)) throw new Error("Model.js no longer starts with " + pragma)
  const context = vm.createContext({})
  new vm.Script("/*pragma libr*/" + source.slice(pragma.length), { filename: MODEL_PATH }).runInContext(context)
  return context
}

module.exports = { loadModel }

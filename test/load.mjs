// Loads a QML .js library under node.
//
// QML library scripts open with `.pragma library` and declare dependencies with
// `.import "Other.js" as Alias`. Node understands neither, so the directives are
// read, stripped, and re-supplied: each `.import` is resolved recursively and
// bound as a function parameter of the same alias, which is exactly the scope
// QML gives it. The `module.exports` tail every library ends with then works.
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const HERE = dirname(fileURLToPath(import.meta.url))
export const LIB = join(HERE, "..", "lib")
export const FIXTURES = join(HERE, "fixtures")

const cache = new Map()

export function loadLib(name) {
  if (cache.has(name)) return cache.get(name)

  const raw = readFileSync(join(LIB, name), "utf8")
  const imports = []
  const body = raw
    .split("\n")
    .map(line => {
      const imp = line.match(/^\s*\.import\s+"([^"]+)"\s+as\s+([A-Za-z_$][\w$]*)/)
      if (imp) {
        imports.push({ file: imp[1], alias: imp[2] })
        return ""
      }
      return /^\s*\.pragma\b/.test(line) ? "" : line
    })
    .join("\n")

  const module = { exports: {} }
  cache.set(name, module.exports)   // set first so a cycle resolves to the partial
  const aliases = imports.map(i => i.alias)
  const values = imports.map(i => loadLib(i.file))
  new Function("module", "exports", ...aliases, body)(module, module.exports, ...values)
  cache.set(name, module.exports)
  return module.exports
}

export function fixture(name) {
  return JSON.parse(readFileSync(join(FIXTURES, name), "utf8"))
}

export function fixtureText(name) {
  return readFileSync(join(FIXTURES, name), "utf8")
}

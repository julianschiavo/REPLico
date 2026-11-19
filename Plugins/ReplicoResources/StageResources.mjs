import { constants, copyFileSync, mkdirSync } from "node:fs"
import path from "node:path"

const destination = path.join(process.argv[2], "NodeRuntime.bundle")
mkdirSync(destination, { recursive: true })
copyFileSync(process.execPath, path.join(destination, "node"), constants.COPYFILE_FICLONE)
copyFileSync(path.join(path.dirname(process.execPath), "LICENSE"), path.join(destination, "LICENSE"))

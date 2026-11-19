import { readFile, realpath, stat } from "node:fs/promises"
import { isBuiltin } from "node:module"
import path from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"
import { SourceTextModule, SyntheticModule } from "node:vm"
import { activeScope } from "./execution-scope.mjs"
import { WorkerError } from "./errors.mjs"

function builtinSpecifier(specifier) {
    if (typeof specifier !== "string") {
        throw new TypeError("Module specifier must be a string")
    }
    const builtin = specifier.startsWith("node:") ? specifier : "node:" + specifier
    if (builtin === "node:process") {
        throw new WorkerError("The process module is unavailable", "import")
    }
    if (isBuiltin(builtin)) {
        return builtin
    }
    if (specifier.startsWith("node:")) {
        throw new WorkerError(`Unknown built-in module: ${specifier}`, "import")
    }
}

export class ModuleLoader {
    #context
    #cwd
    #moduleDirectories = []
    #localModules = new Map()
    #sharedModules = new Map()
    #linking = Promise.resolve()
    #evaluations = new WeakMap()

    constructor(context, cwd) {
        this.#context = context
        this.#cwd = cwd
    }

    beginEvaluation(moduleDirectories = []) {
        this.#localModules = new Map()
        this.#moduleDirectories = moduleDirectories
    }

    async runStartup(source, identifier) {
        const module = this.#module(source, identifier)
        await module.link((specifier, parent) => this.#link(specifier, parent))
        await module.evaluate()
    }

    #link(specifier, referencingModule) {
        const builtin = builtinSpecifier(specifier)
        return builtin === undefined ? this.#load(specifier, referencingModule.identifier) : this.#shared(builtin, {})
    }

    async dynamicImport(specifier, referencingModule, attributes = {}) {
        activeScope()
        const builtin = builtinSpecifier(specifier)
        if (builtin !== undefined) {
            return import(builtin, { with: attributes })
        }
        const module = await this.#load(specifier, referencingModule.identifier, attributes)
        const linking = this.#linking.then(async () => {
            if (module.status === "unlinked") {
                await module.link((dependency, parent) => this.#link(dependency, parent))
            }
        })
        this.#linking = linking.catch(() => undefined)
        await linking
        let evaluation = this.#evaluations.get(module)
        if (evaluation === undefined && module.status === "linked") {
            evaluation = module.evaluate()
            this.#evaluations.set(module, evaluation)
        }
        if (evaluation !== undefined) {
            await evaluation
        }
        if (module.status === "errored") {
            throw module.error
        }
        return module
    }

    async #load(specifier, parentIdentifier, attributes = {}) {
        if (specifier.startsWith("./") || specifier.startsWith("../") || path.isAbsolute(specifier) || specifier.startsWith("file:")) {
            const parent = parentIdentifier.startsWith("file:") ? parentIdentifier : pathToFileURL(path.join(this.#cwd, "execution.mjs")).href
            const url = new URL(specifier, parent)
            if (url.protocol !== "file:") {
                throw new WorkerError("Local imports require a file URL", "import")
            }
            return this.#local(fileURLToPath(url))
        }
        if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(specifier)) {
            throw new WorkerError("Only local files, packages, and Node built-ins may be imported", "import")
        }
        let lastError
        for (const directory of [path.join(this.#cwd, "node_modules"), ...this.#moduleDirectories]) {
            let canonicalDirectory
            try {
                canonicalDirectory = await realpath(directory)
                if (!(await stat(canonicalDirectory)).isDirectory()) {
                    continue
                }
            } catch {
                // Optional dependency roots can be missing or become unavailable.
                continue
            }
            try {
                const parentURL = pathToFileURL(path.join(path.dirname(directory), "__replico_resolve__.mjs"))
                const resolved = import.meta.resolve(specifier, parentURL.href)
                const canonicalFile = await realpath(fileURLToPath(resolved))
                const relative = path.relative(canonicalDirectory, canonicalFile)
                if (relative.startsWith(`..${path.sep}`) || relative === ".." || path.isAbsolute(relative)) {
                    lastError = new WorkerError(`Package resolves outside its configured module directory: ${specifier}`, "import")
                    continue
                }
                return this.#shared(pathToFileURL(canonicalFile).href, attributes)
            } catch (error) {
                if (error?.code !== "ERR_MODULE_NOT_FOUND" && error?.code !== "ERR_PACKAGE_PATH_NOT_EXPORTED" && error?.code !== "ENOENT") {
                    throw error
                }
                lastError = error
            }
        }
        throw new WorkerError(lastError?.message ?? `Cannot resolve package: ${specifier}`, "import")
    }

    #local(filename) {
        const extension = path.extname(filename)
        if (extension !== ".js" && extension !== ".mjs") {
            throw new WorkerError("Local module imports require .js or .mjs files", "import")
        }
        let module = this.#localModules.get(filename)
        if (module === undefined) {
            module = readFile(filename, "utf8").then(source =>
                this.#module(source, pathToFileURL(filename).href, (meta, module) => {
                    meta.url = module.identifier
                }))
            this.#localModules.set(filename, module)
        }
        return module
    }

    #module(source, identifier, initializeImportMeta) {
        return new SourceTextModule(source, {
            context: this.#context, identifier, initializeImportMeta,
            importModuleDynamically: (specifier, parent, attributes) => this.dynamicImport(specifier, parent, attributes),
        })
    }

    #shared(specifier, attributes) {
        const key = `${specifier}\0${JSON.stringify(attributes)}`
        let module = this.#sharedModules.get(key)
        if (module === undefined) {
            module = import(specifier, { with: attributes }).then(namespace => {
                const names = Object.keys(namespace)
                return new SyntheticModule(names, function () {
                    for (const name of names) {
                        this.setExport(name, namespace[name])
                    }
                }, { context: this.#context, identifier: specifier })
            })
            this.#sharedModules.set(key, module)
        }
        return module
    }
}

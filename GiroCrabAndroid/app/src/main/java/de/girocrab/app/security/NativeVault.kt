package de.girocrab.app.security

import java.io.File

/**
 * Handle on an open vault of `girocrab-core`, reached through the UniFFI bindings.
 *
 * Reading data stays in Rust: this type only exposes what the Kotlin side needs to prove it
 * really opened the vault (account count and names) until the snapshot mapper from #1429 (3.1)
 * arrives. Nothing here re-implements core logic.
 */
interface OwnVault : AutoCloseable {
    val accountCount: Int
    val accountNames: List<String>
}

/**
 * Opens vaults through the generated Kotlin bindings (`uniffi.girocrab_core.Vault`).
 *
 * The bindings are reached by reflection, exactly like `CorePaymentParser`: the app has to
 * build and run without the native library, and every call then simply reports "no core"
 * instead of failing at class load time.
 */
class NativeVaultOpener {

    val available: Boolean get() = entry != null

    /**
     * Opens (or creates) the vault at [path] with the raw 32-byte master key.
     *
     * Returns null when the core is not linked; a key of the wrong length is refused before
     * anything is touched, and `CoreException` from the core (wrong key, corrupt file) surfaces
     * unchanged to the caller.
     */
    fun open(path: String, key: ByteArray): OwnVault? {
        require(key.size == MASTER_KEY_BYTES) {
            "master key must be $MASTER_KEY_BYTES bytes, was ${key.size}"
        }
        val resolved = entry ?: return null
        val handle = resolved.openMethod.invoke(resolved.receiver, path, key) ?: return null
        return Handle(handle)
    }

    /** Path the app keeps its own vault at; `vaults/` is runtime data, never in the repository. */
    fun defaultVaultPath(filesDir: File): String =
        File(File(filesDir, "vaults"), "girocrab.sqlcipher").path

    // --- reflection plumbing -------------------------------------------------------------

    /**
     * Kotlin companion functions are only `static` on the class when annotated with `@JvmStatic`;
     * UniFFI does not do that. So the receiver is either the class itself or its `Companion`
     * instance — resolved by looking for the method, not by guessing.
     */
    /**
     * The method is resolved together with its receiver: looking it up on the class while the
     * receiver is the `Companion` throws `NoSuchMethodException` at call time (found the hard
     * way in CI).
     */
    private class Entry(val openMethod: java.lang.reflect.Method, val receiver: Any?)

    private val entry: Entry? by lazy {
        val cls = runCatching { Class.forName(VAULT_CLASS) }.getOrNull() ?: return@lazy null
        findOpen(cls)?.let { return@lazy Entry(it, null) }
        val companion = runCatching { cls.getField("Companion").get(null) }.getOrNull()
            ?: return@lazy null
        findOpen(companion.javaClass)?.let { Entry(it, companion) }
    }

    private fun findOpen(target: Class<*>): java.lang.reflect.Method? =
        runCatching { target.getMethod("open", String::class.java, ByteArray::class.java) }.getOrNull()

    private class Handle(private val vault: Any) : OwnVault {
        override val accountCount: Int
            get() {
                // `accountCount(): UInt` is erased to a plain int on the JVM.
                val raw = call("accountCount") ?: return 0
                return (raw as? Number)?.toInt() ?: 0
            }

        override val accountNames: List<String>
            get() {
                val list = call("listAccounts") as? List<*> ?: return emptyList()
                return list.mapNotNull { account ->
                    runCatching {
                        account?.javaClass?.getMethod("getName")?.invoke(account) as? String
                    }.getOrNull()
                }
            }

        /** UniFFI objects implement AutoCloseable; older bindings used `destroy`. */
        override fun close() {
            val closed = runCatching { vault.javaClass.getMethod("close").invoke(vault) }.isSuccess
            if (!closed) runCatching { vault.javaClass.getMethod("destroy").invoke(vault) }
        }

        private fun call(name: String): Any? =
            runCatching { vault.javaClass.getMethod(name).invoke(vault) }.getOrNull()
    }

    companion object {
        /** Matches `Vault::open`: the raw master key is 32 bytes and wiped by the core. */
        const val MASTER_KEY_BYTES = 32
        private const val VAULT_CLASS = "uniffi.girocrab_core.Vault"
    }
}

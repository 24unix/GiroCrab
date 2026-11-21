package de.girocrab.app.security

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.SecureRandom
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Proves that the app really reaches `girocrab-core` through the generated bindings: a vault is
 * created, closed and reopened, and its account count is read through the handle. If the
 * reflection plumbing breaks (renamed companion, changed signature), this fails — `assembleDebug`
 * would not, because the app deliberately compiles without the bindings.
 */
@RunWith(AndroidJUnit4::class)
class NativeVaultTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val dir = File(context.filesDir, "test-native-vault")
    private val opener = NativeVaultOpener()

    @Before
    fun clean() {
        dir.deleteRecursively()
        dir.mkdirs()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    @Test
    fun bindingsAreOnTheClasspath() {
        assertTrue("native bindings missing: did the build script run?", opener.available)
    }

    @Test
    fun opensFreshVaultAndReadsTheAccountCount() {
        val path = File(dir, "fresh.sqlcipher").path
        val key = randomKey()

        val created = handle(opener.open(path, key), "opener returned no handle (core not linked?)")
        try {
            assertEquals(0, created.accountCount)
            assertEquals(emptyList<String>(), created.accountNames)
        } finally {
            created.close()
        }

        assertTrue("vault file was not written", File(path).length() > 0)

        // Reopening is the real proof: the file must be a vault the core accepts again.
        val reopened = handle(opener.open(path, key), "reopening returned no handle")
        try {
            assertEquals(0, reopened.accountCount)
        } finally {
            reopened.close()
        }
    }

    @Test
    fun wrongKeyIsRefused() {
        val path = File(dir, "wrong-key.sqlcipher").path
        handle(opener.open(path, randomKey()), "could not create the test vault").close()

        // SQLCipher may fail at open or at the first query; both must fail.
        assertThrows(Exception::class.java) {
            val wrong = handle(opener.open(path, randomKey()), "open returned no handle")
            try {
                wrong.accountCount
            } finally {
                wrong.close()
            }
        }
    }

    @Test
    fun shortKeyIsRefusedBeforeTheCoreIsTouched() {
        val path = File(dir, "short-key.sqlcipher").path
        assertThrows(IllegalArgumentException::class.java) {
            opener.open(path, ByteArray(16))
        }
        assertTrue("no vault may be created for a rejected key", !File(path).exists())
    }

    @Test
    fun defaultPathLivesOutsideTheRepository() {
        val path = opener.defaultVaultPath(context.filesDir)
        assertTrue(path.endsWith("vaults/girocrab.sqlcipher"))
        assertTrue(path.startsWith(context.filesDir.path))
    }

    /**
     * A missing handle is an assertion failure, not a `NullPointerException`: `open` returns null
     * both when the core is absent and when reflection lost the constructor, and the message
     * should say which expectation broke.
     */
    private fun handle(vault: OwnVault?, message: String): OwnVault =
        vault ?: throw AssertionError(message)

    private fun randomKey(): ByteArray = ByteArray(NativeVaultOpener.MASTER_KEY_BYTES).also {
        SecureRandom().nextBytes(it)
    }
}

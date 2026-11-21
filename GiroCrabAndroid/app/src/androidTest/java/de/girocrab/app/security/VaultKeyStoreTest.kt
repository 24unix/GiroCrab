package de.girocrab.app.security

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.KeyStore
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Covers the wrap/unwrap mechanics of [VaultKeyStore] on a real Keystore.
 *
 * The biometric gate itself is not exercised here: an emulator/CI device has no enrolled
 * biometric to hand `BiometricPrompt` a `CryptoObject`. These tests therefore use
 * `requireUserAuthentication = false` — the same code path, minus the authentication
 * requirement — so a broken file format, a leftover key or a size check still fails here.
 */
@RunWith(AndroidJUnit4::class)
class VaultKeyStoreTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val alias = "girocrab.test.wrap"
    private val wrappedFile = File(File(context.filesDir, "test-vault"), "device-key.bin")

    private fun store(file: File = wrappedFile) =
        VaultKeyStore(file, alias, requireUserAuthentication = false)

    @Before
    fun clean() {
        deleteAlias()
        File(context.filesDir, "test-vault").deleteRecursively()
    }

    @After
    fun tearDown() {
        File(context.filesDir, "test-vault").deleteRecursively()
        deleteAlias()
    }

    @Test
    fun nothingStoredMeansNotSetUp() {
        assertEquals(VaultKeyStore.State.NotSetUp, store().state())
    }

    @Test
    fun wrapsAndReadsBackTheVaultKey() {
        val key = ByteArray(VaultKeyStore.VAULT_KEY_BYTES) { (it * 7 + 3).toByte() }
        val writer = store()
        writer.storeWrapped(key, writer.setupCipher())

        val reader = store()
        assertEquals(VaultKeyStore.State.Ready, reader.state())
        assertArrayEquals(key, reader.readWrapped(reader.unlockCipher()))
    }

    @Test
    fun secondWriteReplacesTheFirst() {
        val first = ByteArray(VaultKeyStore.VAULT_KEY_BYTES) { 1 }
        val second = ByteArray(VaultKeyStore.VAULT_KEY_BYTES) { 2 }
        val s = store()
        s.storeWrapped(first, s.setupCipher())
        s.storeWrapped(second, s.setupCipher())

        assertArrayEquals(second, s.readWrapped(s.unlockCipher()))
    }

    @Test
    fun wrongKeyLengthIsRejectedBeforeAnythingIsWritten() {
        val s = store()
        assertThrows(IllegalArgumentException::class.java) {
            s.storeWrapped(ByteArray(16) { 9 }, s.setupCipher())
        }
        assertEquals(VaultKeyStore.State.NotSetUp, s.state())
    }

    @Test
    fun clearingLeavesTheKeystoreKeyButNoWrappedCopy() {
        val s = store()
        s.storeWrapped(ByteArray(VaultKeyStore.VAULT_KEY_BYTES) { 4 }, s.setupCipher())
        s.clearWrapped()

        assertEquals(VaultKeyStore.State.NotSetUp, store().state())
        // The alias survives on purpose: a new setup reuses it instead of gambling on a new key.
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        assertTrue("Keystore entry '$alias' must survive clearWrapped()", keyStore.containsAlias(alias))
    }

    /**
     * The wrapped file alone is worthless: if the Keystore entry is gone, the state must say so
     * instead of quietly generating a key that cannot decrypt the file.
     */
    @Test
    fun missingKeystoreEntryIsReportedAsInvalidated() {
        val s = store()
        s.storeWrapped(ByteArray(VaultKeyStore.VAULT_KEY_BYTES) { 7 }, s.setupCipher())
        deleteAlias()

        assertEquals(VaultKeyStore.State.Invalidated, store().state())
    }

    @Test
    fun truncatedFileIsReportedAsInvalidated() {
        val s = store()
        s.storeWrapped(ByteArray(VaultKeyStore.VAULT_KEY_BYTES) { 5 }, s.setupCipher())
        val bytes = wrappedFile.readBytes()
        wrappedFile.writeBytes(bytes.copyOf(3))

        assertEquals(VaultKeyStore.State.Invalidated, store().state())
    }

    /** A blob with a non-12-byte IV cannot be opened by the Keystore; it must be refused up front. */
    @Test
    fun foreignIvLengthIsReportedAsInvalidated() {
        wrappedFile.parentFile?.mkdirs()
        wrappedFile.writeBytes(byteArrayOf(1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

        assertEquals(VaultKeyStore.State.Invalidated, store().state())
    }

    @Test
    fun tamperedCiphertextFailsToUnwrap() {
        val s = store()
        s.storeWrapped(ByteArray(VaultKeyStore.VAULT_KEY_BYTES) { 6 }, s.setupCipher())
        val bytes = wrappedFile.readBytes()
        bytes[bytes.size - 1] = (bytes[bytes.size - 1].toInt() xor 0x01).toByte()
        wrappedFile.writeBytes(bytes)

        val reader = store()
        assertThrows(Exception::class.java) {
            reader.readWrapped(reader.unlockCipher())
        }
    }

    private fun deleteAlias() {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
    }
}

package de.girocrab.app.security

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import java.io.File
import java.security.InvalidAlgorithmParameterException
import java.security.KeyStore
import java.security.UnrecoverableKeyException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Holds this device's 32-byte vault key, wrapped by an AES-GCM key that lives in the
 * `AndroidKeyStore` and is only usable after a successful biometric authentication.
 *
 * The Keystore key never leaves the secure hardware. What lies in `filesDir` is the
 * *wrapped* vault key — useless without a biometric prompt on this device:
 *
 * ```
 * file layout (version 1)
 *   0        1 version
 *   1        1 IV length in bytes (always 12: Android Keystore requires it for GCM)
 *   2..13    IV
 *   14..     AES-GCM ciphertext of the 32-byte vault key (tag appended)
 * ```
 *
 * Invariants this class relies on (and does not weaken):
 * - `setUserAuthenticationRequired(true)` — every wrap/unwrap needs an authenticated cipher
 *   from `BiometricPrompt` (`CryptoObject`).
 * - `setInvalidatedByBiometricEnrollment(true)` — a newly enrolled fingerprint (an attacker
 *   with the device PIN) invalidates the key instead of gaining access.
 * - A reset or removed device lock invalidates the key as well (Keystore behaviour), which is
 *   why restore-from-backup is the only way back (`Vault::restore_backup`, see #1428/2.6).
 *
 * The caller must not keep the returned vault key longer than the open vault needs it; Kotlin
 * cannot wipe a `ByteArray` on its own, so [readWrapped] returns a fresh copy and the caller
 * is expected to drop it (`vaultKey.fill(0)` once the core has opened the vault).
 */
class VaultKeyStore(
    private val wrappedFile: File,
    private val alias: String = DEFAULT_ALIAS,
    private val keyStore: KeyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) },
    /**
     * Only for instrumented tests: an emulator has no biometric to authenticate the cipher with,
     * and a user-auth-required key cannot be used without one. Production code never passes
     * `false` — the app relies on `setUserAuthenticationRequired` being on.
     */
    private val requireUserAuthentication: Boolean = true,
) {
    /** What the UI has to show before touching the vault. */
    enum class State {
        /** A wrapped key exists and the Keystore key is still usable. */
        Ready,

        /** Nothing wrapped yet — the app was never set up on this device (or the file was cleared). */
        NotSetUp,

        /** The Keystore key is gone or invalidated; the vault can only come back from a backup. */
        Invalidated,
    }

    /**
     * Inspects the stored state without creating anything: a missing Keystore entry means the
     * wrapped file cannot be opened, and reporting [State.Ready] there would be a lie.
     */
    fun state(): State {
        // A missing file means "never set up"; a file that is too short to be a v1 record means
        // the stored copy is broken — that is not the same thing and must not look like a fresh start.
        if (!wrappedFile.isFile) return State.NotSetUp
        if (wrappedFile.length() < MIN_BLOB_BYTES) return State.Invalidated
        val header = try {
            readHeader()
        } catch (_: IllegalStateException) {
            return State.Invalidated
        }
        val key = findKey() ?: return State.Invalidated
        return try {
            // Initialising with the stored IV is enough to let the Keystore report an invalidated
            // key; it authenticates nothing and does not prompt.
            Cipher.getInstance(TRANSFORMATION).init(
                Cipher.DECRYPT_MODE,
                key,
                GCMParameterSpec(TAG_BITS, header.iv),
            )
            State.Ready
        } catch (_: KeyPermanentlyInvalidatedException) {
            State.Invalidated
        } catch (_: UnrecoverableKeyException) {
            State.Invalidated
        } catch (_: InvalidAlgorithmParameterException) {
            State.Invalidated
        }
    }

    /**
     * Cipher to hand to `BiometricPrompt` while setting up: the prompt authenticates it and
     * [storeWrapped] then encrypts the freshly generated vault key with it.
     */
    fun setupCipher(): Cipher = try {
        Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, createOrGetKey()) }
    } catch (e: KeyPermanentlyInvalidatedException) {
        // Reusing the dead alias would fail forever; wiping it silently would throw away the only
        // wrapped copy. The caller decides: resetForNewSetup() and restore from a backup.
        throw IllegalStateException(
            "Der Geräteschlüssel ist ungültig. Erst resetForNewSetup() aufrufen und die Sicherung einspielen.",
            e,
        )
    }

    /**
     * Wraps [vaultKey] with the authenticated [cipher] and writes it atomically.
     *
     * A failed rename leaves the previous file untouched: the old wrapped key is the only way
     * into an existing vault, so it must never be deleted to make room for a new one.
     */
    fun storeWrapped(vaultKey: ByteArray, cipher: Cipher) {
        require(vaultKey.size == VAULT_KEY_BYTES) {
            "vault key must be $VAULT_KEY_BYTES bytes, was ${vaultKey.size}"
        }
        val iv = cipher.iv
        require(iv.size == GCM_IV_BYTES) { "unexpected IV length ${iv.size}" }
        val ciphertext = cipher.doFinal(vaultKey)

        val blob = ByteArray(HEADER_BYTES + iv.size + ciphertext.size)
        blob[0] = FORMAT_VERSION
        blob[1] = iv.size.toByte()
        iv.copyInto(blob, destinationOffset = HEADER_BYTES)
        ciphertext.copyInto(blob, destinationOffset = HEADER_BYTES + iv.size)

        val dir = wrappedFile.parentFile
        if (dir != null && !dir.isDirectory) dir.mkdirs()
        val tmp = File(wrappedFile.path + ".tmp")
        tmp.writeBytes(blob)
        if (!tmp.renameTo(wrappedFile)) {
            // Do not delete the destination: without the previous file the vault is unreachable.
            tmp.delete()
            error("could not move ${tmp.path} to ${wrappedFile.path}; previous wrapped key kept")
        }
    }

    /**
     * Cipher to hand to `BiometricPrompt` when unlocking; it is initialised with the IV stored
     * next to the wrapped key, so the prompt authenticates exactly this decryption.
     */
    fun unlockCipher(): Cipher {
        val header = readHeader()
        val key = findKey() ?: error("Keystore entry '$alias' is missing; the vault must be restored")
        return Cipher.getInstance(TRANSFORMATION).apply {
            init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, header.iv))
        }
    }

    /** Returns the vault key after [cipher] has been authenticated by the prompt. */
    fun readWrapped(cipher: Cipher): ByteArray {
        val header = readHeader()
        val plain = cipher.doFinal(header.ciphertext)
        if (plain.size != VAULT_KEY_BYTES) {
            plain.fill(0)
            throw IllegalStateException("unwrapped key has ${plain.size} bytes, expected $VAULT_KEY_BYTES")
        }
        return plain
    }

    /**
     * Drops both the wrapped key and the Keystore entry — the only way out of [State.Invalidated]:
     * an invalidated key can never be used again, so keeping it only blocks every later setup.
     * Afterwards the vault has to come back from a backup (#1428, 2.6).
     */
    fun resetForNewSetup() {
        clearWrapped()
        runCatching { keyStore.deleteEntry(alias) }
    }

    /** Drops the wrapped key. The Keystore entry stays; [state] returns [State.NotSetUp] afterwards. */
    fun clearWrapped() {
        wrappedFile.delete()
        File(wrappedFile.path + ".tmp").delete()
    }

    // --- internals -------------------------------------------------------------------------

    private class Header(val iv: ByteArray, val ciphertext: ByteArray)

    private fun readHeader(): Header {
        val blob = wrappedFile.readBytes()
        check(blob.size >= MIN_BLOB_BYTES) { "wrapped key is ${blob.size} bytes, too short" }
        check(blob[0] == FORMAT_VERSION) { "unknown wrapped key format ${blob[0]}" }
        val ivSize = blob[1].toInt() and 0xFF
        check(ivSize == GCM_IV_BYTES) { "IV length $ivSize, expected $GCM_IV_BYTES" }
        val iv = blob.copyOfRange(HEADER_BYTES, HEADER_BYTES + ivSize)
        val ciphertext = blob.copyOfRange(HEADER_BYTES + ivSize, blob.size)
        return Header(iv, ciphertext)
    }

    /** Lookup only — never creates a key, so a state check cannot silently mint a new one. */
    private fun findKey(): SecretKey? = try {
        keyStore.getKey(alias, null) as? SecretKey
    } catch (_: UnrecoverableKeyException) {
        null
    }

    private fun createOrGetKey(): SecretKey = findKey() ?: generateKey()

    private fun generateKey(): SecretKey {
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val spec = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(requireUserAuthentication)
            // New biometric enrolment must not yield access to an existing vault.
            .setInvalidatedByBiometricEnrollment(requireUserAuthentication)
        if (requireUserAuthentication) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // 0 seconds = authenticate for every use; only strong biometrics are accepted.
                spec.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
            } else {
                @Suppress("DEPRECATION")
                spec.setUserAuthenticationValidityDurationSeconds(-1)
            }
        }
        generator.init(spec.build())
        return generator.generateKey()
    }

    companion object {
        const val DEFAULT_ALIAS = "girocrab.vault.wrap"
        const val VAULT_KEY_BYTES = 32

        /** Android Keystore requires a 12-byte IV for GCM; anything else is refused at init. */
        const val GCM_IV_BYTES = 12
        private const val TAG_BITS = 128
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val FORMAT_VERSION: Byte = 1
        private const val HEADER_BYTES = 2

        /** 2 header + 12 IV + 32 key + 16 GCM tag: anything shorter cannot be a v1 record. */
        private const val MIN_BLOB_BYTES = HEADER_BYTES + GCM_IV_BYTES + VAULT_KEY_BYTES + 16

        /**
         * Nothing has to be stored before the Keystore key exists: the setup path creates it.
         * The alias is fixed, so a reinstall creates a new key — an old wrapped blob is useless
         * then, which is why [state] reports [State.Invalidated] for it.
         */
        fun defaultFile(filesDir: File): File = File(File(filesDir, "vault"), "device-key.bin")
    }
}

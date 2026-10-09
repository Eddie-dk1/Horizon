import Foundation
import CryptoKit
import CommonCrypto
import Security

enum VaultCrypto {
    static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw HorizonError.message("Не удалось создать криптографический ключ.")
        }
        return Data(bytes)
    }
    static func normalized(_ password: String) -> String { password.precomposedStringWithCanonicalMapping }
    static func validatePassword(_ password: String) throws {
        guard (12...256).contains(normalized(password).count) else {
            throw HorizonError.message("Пароль должен содержать от 12 до 256 символов. Пробелы разрешены.")
        }
    }
    static func pbkdf(_ password: Data, salt: Data, rounds: UInt32) throws -> Data {
        var result = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBytes { pass in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &result, 32)
            }
        }
        guard status == kCCSuccess else { throw HorizonError.message("Ошибка получения ключа из пароля.") }
        defer { result.withUnsafeMutableBytes { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        return Data(result)
    }
    static func passwordKey(_ password: String, header: Header) throws -> SymmetricKey {
        guard header.version == 1, header.rounds == 600_000, header.salt.count == 32,
            header.passwordWrap.count == 60, header.recoveryWrap.count == 60 else {
            throw HorizonError.message("Неподдерживаемый или повреждённый заголовок хранилища.")
        }
        guard normalized(password).count <= 256 else { throw HorizonError.message("Слишком длинный пароль.") }
        return SymmetricKey(data: try pbkdf(Data(normalized(password).utf8), salt: header.salt, rounds: header.rounds))
    }
    static func subkey(_ master: SymmetricKey, vault: UUID, purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data(vault.uuidString.utf8), info: Data(("Horizon.v1." + purpose).utf8), outputByteCount: 32)
    }
    static func seal(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8)).combined else {
            throw HorizonError.message("Ошибка шифрования.")
        }
        return combined
    }
    static func open(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(context.utf8))
    }
    static func recoveryString(_ data: Data) -> String {
        let hex = data.map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: 64, by: 8).map { String(hex.dropFirst($0).prefix(8)) }.joined(separator: "-")
    }
    static func recoveryData(_ code: String) throws -> Data {
        let normalized = code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard normalized.count == 64, normalized.allSatisfy({ "0123456789ABCDEF".contains($0) }) else {
            throw HorizonError.message("Ключ восстановления должен содержать 8 групп по 8 символов.")
        }
        let chars = Array(normalized)
        return Data(stride(from: 0, to: 64, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! })
    }
}

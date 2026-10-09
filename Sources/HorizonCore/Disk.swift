import Foundation
import Darwin

enum Disk {
    static var fm: FileManager { FileManager() }
    static func directory(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requireDirectory(url)
    }
    static func requireDirectory(_ url: URL) throws {
        let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard v.isDirectory == true, v.isSymbolicLink != true else { throw HorizonError.message("Небезопасный путь к хранилищу.") }
    }
    static func regular(_ url: URL) throws {
        let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard v.isRegularFile == true, v.isSymbolicLink != true else { throw HorizonError.message("Выберите обычный файл. Папки, ссылки и пакеты пока не поддерживаются.") }
    }
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw HorizonError.message("Не удалось прочитать файл хранилища.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= maximum else {
            throw HorizonError.message("Файл хранилища повреждён или превышает допустимый размер.")
        }
        let data = try exact(handle, count: Int(info.st_size))
        guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw HorizonError.message("Файл хранилища изменился во время чтения.") }
        return data
    }
    static func newFile(_ url: URL) throws -> FileHandle {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HorizonError.message("Не удалось создать файл. Проверьте свободное место и права доступа.") }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    static func syncDirectory(_ url: URL) {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        if fd >= 0 { _ = fsync(fd); Darwin.close(fd) }
    }
    static func replace(_ source: URL, _ destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else { throw HorizonError.message("Не удалось завершить запись на диск.") }
        syncDirectory(destination.deletingLastPathComponent())
    }
    static func moveExclusive(_ source: URL, _ destination: URL) throws {
        guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw HorizonError.message("Не удалось сохранить копию. По этому пути уже есть файл или нет прав на запись.")
        }
        syncDirectory(destination.deletingLastPathComponent())
    }
    static func atomic(_ data: Data, to destination: URL) throws {
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        let file = try newFile(temp)
        do { try file.write(contentsOf: data); try file.synchronize(); try file.close() }
        catch { try? file.close(); throw error }
        try replace(temp, destination)
    }
    static func readHandle(_ url: URL) throws -> FileHandle {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw HorizonError.message("Не удалось открыть файл.") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { Darwin.close(fd); throw HorizonError.message("Нужен обычный файл.") }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    static func exact(_ handle: FileHandle, count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let next = try handle.read(upToCount: count - result.count), !next.isEmpty else { throw HorizonError.message("Зашифрованный файл усечён.") }
            result.append(next)
        }
        return result
    }
    static func uint32(_ number: UInt32) -> Data { var n = number.bigEndian; return withUnsafeBytes(of: &n) { Data($0) } }
    static func decode32(_ data: Data) -> UInt32 { data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    static func copy(_ source: URL, _ destination: URL, token: OperationToken) throws {
        let input = try readHandle(source); defer { try? input.close() }
        let output = try newFile(destination); defer { try? output.close() }
        while let data = try input.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { try token.check(); try output.write(contentsOf: data) }
        try output.synchronize()
    }
}

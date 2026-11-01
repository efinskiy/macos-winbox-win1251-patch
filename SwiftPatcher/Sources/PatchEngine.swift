import CryptoKit
import AppKit
import Darwin
import Foundation

struct PatchEngine {
    let resources: URL
    let profile: PatchProfile
    private let manager = FileManager.default

    init(resources: URL) throws {
        self.resources = resources
        let data = try Data(contentsOf: resources.appendingPathComponent("profile.json"))
        guard data.count < 1048576 else { throw PatchError.invalid("Профиль патча слишком велик.") }
        profile = try JSONDecoder().decode(PatchProfile.self, from: data)
    }

    func inspect(_ url: URL) throws -> TargetApplication {
        let source = url.resolvingSymlinksInPath().standardizedFileURL
        let plistURL = source.appendingPathComponent("Contents/Info.plist")
        let plistSize = try manager.attributesOfItem(atPath: plistURL.path)[.size] as? NSNumber
        guard let size = plistSize, size.intValue <= 1048576 else {
            throw PatchError.invalid("Не удалось прочитать описание приложения.")
        }
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL),
            options: [], format: nil) as? [String: Any]
        guard plist?["CFBundleIdentifier"] as? String == "com.mikrotik.winbox",
              plist?["CFBundleExecutable"] as? String == "WinBox" else {
            throw PatchError.invalid("Выберите приложение MikroTik WinBox.")
        }
        let executable = source.appendingPathComponent("Contents/MacOS/WinBox")
        let attributes = try manager.attributesOfItem(atPath: executable.path)
        guard let binarySize = attributes[.size] as? NSNumber,
              binarySize.uint64Value <= 256*1024*1024 else {
            throw PatchError.invalid("Исполняемый файл превышает допустимый размер.")
        }
        let binary = try Data(contentsOf: executable)
        guard hash(binary) == profile.sha256 else {
            let version = plist?["CFBundleShortVersionString"] as? String ?? "неизвестна"
            throw PatchError.invalid("Версия WinBox \(version) не поддерживается этим патчем. Поддерживается точная сборка \(profile.version).")
        }
        return TargetApplication(url: source, version: profile.version, binary: binary)
    }

    func apply(source: URL, encoding: CommentEncoding,
               afterCommit: (() throws -> Void)? = nil,
               progress: (String) -> Void) throws -> AppliedPatch {
        progress("Проверка выбранного WinBox…")
        let target = try inspect(source)
        let parent = target.url.deletingLastPathComponent()
        try requireClosed(target.url)
        guard manager.isWritableFile(atPath: parent.path) else {
            throw PatchError.invalid("Нет прав на изменение приложения в папке \(parent.path).")
        }
        // The pinned executable alone cannot make arbitrary symlinks in a selected bundle safe to copy.
        guard let enumerator = manager.enumerator(at: target.url,
            includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else {
            throw PatchError.invalid("Не удалось проверить состав WinBox.")
        }
        var files = 0
        for case let item as URL in enumerator {
            files += 1
            guard files <= 10000, try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else {
                throw PatchError.invalid("Необычный состав приложения: обнаружена ссылка или слишком много файлов.")
            }
        }
        progress("Добавление поддержки кодировок…")
        let binary = try patchBinary(target.binary)
        let transaction = UUID().uuidString
        // Use a same-volume replacement directory outside File Provider's metadata churn.
        let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                      appropriateFor: target.url, create: true)
        defer { try? manager.removeItem(at: staging) }
        let stagedApp = staging.appendingPathComponent(target.url.lastPathComponent, isDirectory: true)
        progress("Подготовка обновления…")
        try manager.copyItem(at: target.url, to: stagedApp)
        let stagedExecutable = stagedApp.appendingPathComponent("Contents/MacOS/WinBox")
        guard let permissions = try manager.attributesOfItem(atPath: stagedExecutable.path)[.posixPermissions] else {
            throw PatchError.invalid("Не удалось определить права запуска WinBox.")
        }
        try binary.write(to: stagedExecutable, options: .atomic)
        try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: stagedExecutable.path)
        let frameworks = stagedApp.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        try manager.createDirectory(at: frameworks, withIntermediateDirectories: true)
        let library = frameworks.appendingPathComponent("libWinBoxCommentEncoding.dylib")
        if manager.fileExists(atPath: library.path) {
            throw PatchError.invalid("В исходном приложении уже присутствует библиотека патча.")
        }
        try manager.copyItem(at: resources.appendingPathComponent(library.lastPathComponent), to: library)
        try Data("encoding=\(encoding.rawValue)\n".utf8).write(
            to: stagedApp.appendingPathComponent("Contents/Resources/comment-encoding.conf"), options: .atomic)
        progress("Подпись и проверка приложения…")
        try run("/usr/bin/codesign", ["--force", "--sign", "-", library.path])
        try signature(stagedApp, sign: true)
        let signedHash = hash(try Data(contentsOf: stagedExecutable))
        // Keep the final exchange inside the selected folder's File Provider domain.
        // Cross-domain RENAME_SWAP can wait indefinitely even on the same APFS volume.
        let installation = parent.appendingPathComponent(".winbox-patch-" + transaction, isDirectory: true)
        try manager.createDirectory(at: installation, withIntermediateDirectories: false)
        var preserveInstallation = false
        defer { if !preserveInstallation { try? manager.removeItem(at: installation) } }
        let replacement = installation.appendingPathComponent(target.url.lastPathComponent, isDirectory: true)
        try manager.copyItem(at: stagedApp, to: replacement)
        guard hash(try Data(contentsOf: replacement.appendingPathComponent("Contents/MacOS/WinBox"))) == signedHash else {
            throw PatchError.invalid("Контрольная сумма подготовленного обновления не совпала.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", replacement.path])
        let backups = parent.appendingPathComponent(".winbox-comment-backups", isDirectory: true)
        if manager.fileExists(atPath: backups.path) {
            let values = try backups.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink == false else {
                throw PatchError.invalid("Папка резервных копий имеет недопустимый тип.")
            }
        } else {
            try manager.createDirectory(at: backups, withIntermediateDirectories: false)
        }
        let backup = backups.appendingPathComponent(transaction + ".zip")
        let journal = backups.appendingPathComponent(transaction + ".json")
        progress("Сохранение резервной копии…")
        do {
            try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", target.url.path, backup.path])
        } catch {
            try? manager.removeItem(at: backup)
            throw error
        }
        func record(_ state: String) throws {
            let data = try JSONSerialization.data(withJSONObject: ["state": state,
                "application": target.url.path, "backup": backup.path,
                "original_sha256": profile.sha256, "patched_sha256": signedHash,
                "encoding": encoding.rawValue, "recovery_application": replacement.path], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: journal, options: .atomic)
        }
        try record("prepared")
        // Recheck immediately before committing; a running process must keep its original bundle.
        _ = try inspect(target.url)
        try requireClosed(target.url)
        progress("Применение патча к выбранному приложению…")
        try exchange(target.url, replacement)
        do {
            guard hash(try Data(contentsOf: target.url.appendingPathComponent("Contents/MacOS/WinBox"))) == signedHash else {
                throw PatchError.invalid("Контрольная сумма после применения патча не совпала.")
            }
            // Strict verification was completed before the swap. Finder may add harmless
            // metadata at the final path; verify the full seal without rejecting that metadata.
            try run("/usr/bin/codesign", ["--verify", "--deep", target.url.path])
            try afterCommit?()
            try record("committed")
        } catch {
            let failure = error
            progress("Восстановление исходного приложения…")
            do {
                try exchange(target.url, replacement)
                _ = try inspect(target.url)
            } catch {
                // Never delete the only intact original if the volume refuses the reverse swap.
                preserveInstallation = true
                try? record("rollback_failed")
                throw PatchError.invalid("Ошибка отката. Исходное приложение сохранено в \(replacement.path). Резервный архив: \(backup.path).\n\(error.localizedDescription)")
            }
            try? record("rolled_back")
            throw PatchError.invalid("Изменения отменены; исходное приложение восстановлено.\n\(failure.localizedDescription)")
        }
        return AppliedPatch(application: target.url, backup: backup)
    }

    private func requireClosed(_ application: URL) throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mikrotik.winbox")
        if running.contains(where: { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == application }) {
            throw PatchError.invalid("Закройте выбранный WinBox перед применением патча.")
        }
    }

    private func exchange(_ application: URL, _ prepared: URL) throws {
        let status = application.path.withCString { source in
            prepared.path.withCString { staged in
                renameatx_np(AT_FDCWD, source, AT_FDCWD, staged, UInt32(RENAME_SWAP))
            }
        }
        guard status == 0 else {
            let detail = String(cString: strerror(errno))
            throw PatchError.invalid("Не удалось атомарно обновить приложение: \(detail).")
        }
    }

    private func signature(_ application: URL, sign: Bool) throws {
        // File Provider can recreate Finder metadata while an app bundle is being prepared.
        // Retry only that explicit metadata failure, never a failed signature or executable check.
        for attempt in 0..<3 {
            for attribute in ["com.apple.FinderInfo", "com.apple.ResourceFork"] {
                try run("/usr/bin/xattr", ["-dr", attribute, application.path])
            }
            do {
                if sign { try run("/usr/bin/codesign", ["--force", "--sign", "-", application.path]) }
                try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", application.path])
                return
            } catch {
                guard attempt < 2, error.localizedDescription.contains("resource fork, Finder information") else { throw error }
            }
        }
    }

    private func patchBinary(_ data: Data) throws -> Data {
        let slices = try FatSlice.read(data)
        var byCPU: [UInt32: (String, ArchitectureProfile)] = [:]
        for (name, configuration) in profile.architectures {
            guard byCPU[configuration.cpu] == nil else { throw PatchError.invalid("Повтор архитектуры в профиле.") }
            byCPU[configuration.cpu] = (name, configuration)
        }
        guard Set(slices.map(\.cpu)) == Set(byCPU.keys), slices.count == byCPU.count else {
            throw PatchError.invalid("Архитектуры приложения не совпадают с профилем патча.")
        }
        var patched = BinaryImage(data: data)
        for slice in slices {
            guard let (name, configuration) = byCPU[slice.cpu] else {
                throw PatchError.invalid("Неподдерживаемая архитектура.")
            }
            var mach = try MachOImage(Data(data[slice.offset..<slice.offset+slice.size]))
            let site = try address(configuration.patch_site), cave = try address(configuration.cave)
            guard site <= UInt64(Int64.max)-5, cave <= UInt64(Int64.max) else {
                throw PatchError.invalid("Адрес патча выходит за пределы архитектуры.")
            }
            let expected = try bytesFromHex(configuration.expected)
            let payload = try Data(contentsOf: resources.appendingPathComponent(name + "-thunk.bin"))
            guard configuration.cave_capacity > 0, configuration.cave_capacity <= 4096,
                  payload.count <= configuration.cave_capacity, cave <= UInt64.max-UInt64(payload.count) else {
                throw PatchError.invalid("Повреждён встроенный код патча.")
            }
            let fileSite = try mach.fileOffset(site, length: expected.count)
            let fileCave = try mach.fileOffset(cave, length: configuration.cave_capacity)
            guard mach.image.data[fileSite..<fileSite+expected.count] == expected,
                  mach.image.data[fileCave..<fileCave+configuration.cave_capacity].allSatisfy({ $0 == 0 }),
                  mach.segments.contains(where: {
                      $0.name == "__TEXT" && $0.protection & 4 != 0 && cave >= $0.address &&
                      cave-$0.address < UInt64($0.fileSize)
                  }),
                  !mach.sections.contains(where: { $0.address < cave+UInt64(payload.count) && cave < $0.address+$0.size }) else {
                throw PatchError.invalid("Инструкции WinBox или свободная область не совпадают с профилем.")
            }
            let branch: Data
            if name == "arm64" {
                let delta = Int64(cave) - Int64(site)
                guard expected.count == 4, delta % 4 == 0, delta >= -(1 << 27), delta < (1 << 27) else {
                    throw PatchError.invalid("Недопустимое расстояние перехода arm64.")
                }
                var instruction = BinaryImage(data: Data(repeating: 0, count: 4))
                try instruction.write(0x14000000 | (UInt64(bitPattern: delta/4) & 0x3ffffff), at: 0, width: 4)
                branch = instruction.data
            } else if name == "x86_64" {
                let delta = Int64(cave) - Int64(site) - 5
                guard expected.count >= 5, delta >= Int64(Int32.min), delta <= Int64(Int32.max) else {
                    throw PatchError.invalid("Недопустимое расстояние перехода Intel.")
                }
                var instruction = BinaryImage(data: Data(repeating: 0x90, count: expected.count))
                instruction.data[0] = 0xe9
                try instruction.write(UInt64(bitPattern: delta) & 0xffffffff, at: 1, width: 4)
                branch = instruction.data
            } else { throw PatchError.invalid("Неподдерживаемая архитектура патча.") }
            try mach.addLibrary(profile.dylib)
            try mach.image.replace(at: fileSite, with: branch)
            try mach.image.replace(at: fileCave, with: payload)
            try patched.replace(at: slice.offset, with: mach.image.data)
        }
        return patched.data
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let log = manager.temporaryDirectory.appendingPathComponent("winbox-sign-" + UUID().uuidString)
        guard manager.createFile(atPath: log.path, contents: nil) else {
            throw PatchError.invalid("Не удалось создать временный журнал проверки.")
        }
        defer { try? manager.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 3)
            }
            throw PatchError.invalid("Системная проверка приложения не завершилась за 30 секунд.")
        }
        guard process.terminationStatus == 0 else {
            let reader = try FileHandle(forReadingFrom: log)
            defer { try? reader.close() }
            let detail = String(data: try reader.read(upToCount: 65536) ?? Data(), encoding: .utf8) ?? ""
            throw PatchError.invalid("Системная операция \(URL(fileURLWithPath: executable).lastPathComponent) завершилась ошибкой.\n" + detail)
        }
    }
}

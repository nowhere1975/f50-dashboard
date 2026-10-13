import Foundation

final class StateStore {
    let url: URL
    var backupURL: URL { url.deletingPathExtension().appendingPathExtension("backup.json") }
    private var lastValidData: Data?
    private var protectedCorruptFile = false

    init(url: URL = Config.supportDir.appendingPathComponent("state.json")) { self.url = url }

    func load() -> (state: PersistedState, warning: String?) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let state = try JSONDecoder().decode(PersistedState.self, from: data)
                lastValidData = data
                return (state, nil)
            } catch {
                let copy = url.deletingLastPathComponent().appendingPathComponent("state.corrupt.\(UUID().uuidString).json")
                do { try fm.copyItem(at: url, to: copy) }
                catch { protectedCorruptFile = true }
            }
        }
        if let data = try? Data(contentsOf: backupURL),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            lastValidData = data
            return (state, "累计文件异常，已从备份恢复；原文件已保留")
        }
        return (PersistedState(), fm.fileExists(atPath: url.path)
            ? "累计文件异常，无法恢复；原文件已保留，请检查数据目录" : nil)
    }

    func save(_ state: PersistedState) throws {
        guard !protectedCorruptFile else { throw ConfigError(message: "损坏文件留存失败，已停止覆盖累计文件") }
        let data = try JSONEncoder().encode(state)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let previous = lastValidData { try previous.write(to: backupURL, options: .atomic) }
        try data.write(to: url, options: .atomic)
        lastValidData = data
    }

    /// 迁移前独立留存，避免定时备份轮换后丢失合并前的结构。
    func archiveBeforeF50Merge(_ state: PersistedState) throws -> URL {
        let archive = url.deletingLastPathComponent()
            .appendingPathComponent("state.before-f50-merge.\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(state)
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: archive, options: .atomic)
        return archive
    }
}

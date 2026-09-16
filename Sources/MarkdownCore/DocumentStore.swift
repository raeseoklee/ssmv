import Darwin
import Foundation

/// Persists references separately from durable imported content. Removing a row never removes a file.
@MainActor
public final class DocumentStore {
  public enum StoreError: LocalizedError {
    case emptyText, tooLarge, quotaExceeded, invalidURL, invalidStore, listedImport
    public var errorDescription: String? {
      switch self {
      case .emptyText: "No Markdown text."
      case .tooLarge: "Markdown text exceeds the 16 MiB limit."
      case .quotaExceeded:
        "Imported documents have reached their storage limit. Manage imported documents or save the text to a file."
      case .invalidURL: "Enter a public HTTPS URL without credentials."
      case .invalidStore: "The saved document library could not be read safely."
      case .listedImport: "Remove this document from the sidebar before deleting its imported copy."
      }
    }
  }

  private struct State: Codable {
    var version = 2
    var records: [DocumentRecord] = []
    var selectedID: UUID?
    var imports: [DocumentRecord] = []
    var nextOrdinal = 0
  }

  public static let persistenceKey = "documentStoreV2"
  public static let maximumDocumentBytes = 16 * 1024 * 1024
  public let directory: URL
  private let defaults: UserDefaults
  private let maximumImportedBytes: Int
  private var state: State
  private var indexURL: URL { directory.appendingPathComponent("document-store-v2.json") }
  public var records: [DocumentRecord] { state.records }
  public var selectedID: UUID? { state.selectedID }
  public var selectedRecord: DocumentRecord? { selectedID.flatMap { record($0) } }
  public var unlistedImports: [DocumentRecord] {
    state.imports.filter { imported in !state.records.contains { $0.id == imported.id } }
  }
  public var importedByteCount: Int {
    state.imports.reduce(0) { sum, record in
      sum + ((try? fileURL(for: record)?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
  }

  public init(
    defaults: UserDefaults = .standard, directory: URL? = nil,
    maximumImportedBytes: Int = 256 * 1024 * 1024
  ) throws {
    self.defaults = defaults
    self.directory =
      directory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("SSMV/Documents", isDirectory: true)
    self.maximumImportedBytes = maximumImportedBytes
    self.state = State()
    try FileManager.default.createDirectory(
      at: self.directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let attributes = try FileManager.default.attributesOfItem(atPath: self.directory.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
      throw StoreError.invalidStore
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
    if FileManager.default.fileExists(atPath: indexURL.path) {
      guard
        try FileManager.default.attributesOfItem(atPath: indexURL.path)[.type] as? FileAttributeType
          == .typeRegular
      else { throw StoreError.invalidStore }
      state = try JSONDecoder().decode(State.self, from: Data(contentsOf: indexURL))
      try validate(state)
    } else if let data = defaults.data(forKey: Self.persistenceKey) {
      state = try JSONDecoder().decode(State.self, from: data)
      try validate(state)
      try commit(state)
    } else {
      if let data = defaults.data(forKey: "documentShelf") {
        let shelf = try JSONDecoder().decode(DocumentShelf.self, from: data)
        for url in shelf.urls {
          let record = makeLocal(url, ordinal: state.nextOrdinal)
          state.records.append(record)
          state.nextOrdinal += 1
          if url == shelf.selectedURL { state.selectedID = record.id }
        }
      }
      try commit(state)
    }
  }

  public func record(_ id: UUID) -> DocumentRecord? { state.records.first { $0.id == id } }

  public func fileURL(for record: DocumentRecord) -> URL? {
    switch record.source {
    case .localFile(let url): return url
    case .remote: return nil
    case .imported(let path):
      guard validImportPath(path) else { return nil }
      return directory.appendingPathComponent(path)
    }
  }

  @discardableResult
  public func addLocal(_ urls: [URL]) throws -> [DocumentRecord] {
    var next = state
    var result: [DocumentRecord] = []
    for url in urls {
      guard url.isFileURL else { throw StoreError.invalidURL }
      let source = DocumentRecord.Source.localFile(url.standardizedFileURL)
      let record =
        next.records.first { $0.source == source } ?? makeLocal(url, ordinal: next.nextOrdinal)
      if !next.records.contains(where: { $0.id == record.id }) {
        next.records.append(record)
        next.nextOrdinal += 1
      }
      next.selectedID = record.id
      result.append(record)
    }
    try commit(next)
    return result
  }

  @discardableResult
  public func addRemote(_ url: URL) throws -> DocumentRecord {
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
      parts.user == nil, parts.password == nil
    else { throw StoreError.invalidURL }
    parts.scheme = "https"
    parts.host = host.lowercased()
    parts.fragment = nil
    guard let canonical = parts.url else { throw StoreError.invalidURL }
    var next = state
    let source = DocumentRecord.Source.remote(canonical)
    let record =
      next.records.first { $0.source == source }
      ?? DocumentRecord(
        source: source,
        displayName: canonical.lastPathComponent.isEmpty ? host : canonical.lastPathComponent,
        addedOrdinal: next.nextOrdinal)
    if !next.records.contains(where: { $0.id == record.id }) {
      next.records.append(record)
      next.nextOrdinal += 1
    }
    next.selectedID = record.id
    try commit(next)
    return record
  }

  @discardableResult
  public func importText(_ text: String, title: String? = nil, requestID: UUID? = nil) throws
    -> DocumentRecord
  {
    var next = state
    if let requestID, let existing = next.imports.first(where: { $0.id == requestID }) {
      if !next.records.contains(where: { $0.id == existing.id }) { next.records.append(existing) }
      next.selectedID = existing.id
      try commit(next)
      return existing
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw StoreError.emptyText
    }
    let data = Data(text.utf8)
    guard data.count <= Self.maximumDocumentBytes else { throw StoreError.tooLarge }
    guard data.count <= maximumImportedBytes - importedByteCount else {
      throw StoreError.quotaExceeded
    }
    let id = requestID ?? UUID()
    guard !next.records.contains(where: { $0.id == id }) else { throw StoreError.invalidStore }
    let path = id.uuidString + ".md"
    let record = DocumentRecord(
      id: id, source: .imported(relativePath: path),
      displayName: Self.title(title, text: text), addedOrdinal: next.nextOrdinal,
      sourceModifiedAt: Date())
    let destination = directory.appendingPathComponent(path)
    let adoptedOrphan = try matchingOrphan(at: destination, data: data, allowed: requestID != nil)
    if !adoptedOrphan { try privateWrite(data, to: destination) }
    next.records.append(record)
    next.imports.append(record)
    next.selectedID = id
    next.nextOrdinal += 1
    do { try commit(next) } catch {
      // A recovered payload predates this attempt and must survive another failed commit.
      if !adoptedOrphan { try? FileManager.default.removeItem(at: destination) }
      throw error
    }
    return record
  }

  public func select(_ id: UUID) throws {
    guard record(id) != nil else { return }
    var next = state
    next.selectedID = id
    try commit(next)
  }

  public func remove(_ id: UUID) throws {
    guard let index = state.records.firstIndex(where: { $0.id == id }) else { return }
    var next = state
    next.records.remove(at: index)
    if next.selectedID == id {
      next.selectedID =
        next.records.isEmpty ? nil : next.records[min(index, next.records.count - 1)].id
    }
    try commit(next)
  }

  public func removeAllReferences() throws {
    var next = state
    next.records = []
    next.selectedID = nil
    try commit(next)
  }

  public func deleteUnlistedImport(_ id: UUID) throws {
    guard record(id) == nil else { throw StoreError.listedImport }
    guard let imported = state.imports.first(where: { $0.id == id }),
      let url = fileURL(for: imported)
    else { return }
    // Keep the index on a failed delete so cleanup can be retried.
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    var next = state
    next.imports.removeAll { $0.id == id }
    try commit(next)
  }

  public func updateRemoteMetadata(id: UUID, modifiedAt: Date?, fetchedAt: Date) throws {
    guard let index = state.records.firstIndex(where: { $0.id == id }),
      case .remote = state.records[index].source
    else { return }
    var next = state
    next.records[index].sourceModifiedAt = modifiedAt
    next.records[index].lastFetchedAt = fetchedAt
    try commit(next)
  }

  private func makeLocal(_ url: URL, ordinal: Int) -> DocumentRecord {
    let canonical = url.standardizedFileURL
    return DocumentRecord(
      source: .localFile(canonical), displayName: canonical.lastPathComponent,
      addedOrdinal: ordinal,
      sourceModifiedAt: try? canonical.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate)
  }

  private func commit(_ next: State) throws {
    try validate(next)
    let data = try JSONEncoder().encode(next)
    try privateWrite(data, to: indexURL)
    defaults.set(data, forKey: Self.persistenceKey)
    state = next
  }

  private func matchingOrphan(at url: URL, data: Data, allowed: Bool) throws -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      if errno == ENOENT { return false }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard allowed else { throw StoreError.invalidStore }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw StoreError.invalidStore }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    guard fstat(descriptor, &info) == 0,
      info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
      info.st_size == data.count, info.st_size <= Self.maximumDocumentBytes,
      try handle.read(upToCount: Self.maximumDocumentBytes + 1) == data
    else { throw StoreError.invalidStore }
    return true
  }

  private func privateWrite(_ data: Data, to destination: URL) throws {
    let temporary = directory.appendingPathComponent(".pending-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard
      FileManager.default.createFile(
        atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    if rename(temporary.path, destination.path) != 0 {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private func validImportPath(_ path: String) -> Bool {
    path.hasSuffix(".md") && UUID(uuidString: String(path.dropLast(3))) != nil
  }

  private func validate(_ saved: State) throws {
    guard saved.version == 2, saved.nextOrdinal >= 0,
      Set(saved.records.map(\.id)).count == saved.records.count,
      Set(saved.imports.map(\.id)).count == saved.imports.count,
      saved.selectedID == nil || saved.records.contains(where: { $0.id == saved.selectedID })
    else { throw StoreError.invalidStore }
    for record in saved.imports {
      guard case .imported(let path) = record.source, validImportPath(path) else {
        throw StoreError.invalidStore
      }
      let url = directory.appendingPathComponent(path)
      if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        attributes[.type] as? FileAttributeType != .typeRegular
      {
        throw StoreError.invalidStore
      }
    }
    for record in saved.records {
      if case .imported = record.source, !saved.imports.contains(record) {
        throw StoreError.invalidStore
      }
    }
  }

  private static func title(_ supplied: String?, text: String) -> String {
    var candidate = supplied?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if candidate.isEmpty {
      for line in text.prefix(65536).split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let marks = trimmed.prefix { $0 == "#" }
        if (1...6).contains(marks.count), trimmed.dropFirst(marks.count).first == " " {
          candidate = String(trimmed.dropFirst(marks.count + 1))
          break
        }
      }
    }
    let cleaned = candidate.unicodeScalars.map { scalar -> String in
      CharacterSet.controlCharacters.contains(scalar) || "/\\:".unicodeScalars.contains(scalar)
        ? " " : String(scalar)
    }.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(160))
  }
}

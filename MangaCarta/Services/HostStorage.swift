//
//  HostStorage.swift
//  MangaCarta
//
//  Durable JSON storage with one namespace per opaque qualified Source id. There is no
//  filesystem handle in the Source-facing interface and no automatic uninstall hook.
//

import Foundation

struct HostStorage: Sendable {
    private let sourceID: QualifiedSourceID
    private let repository: HostStorageRepository

    init(sourceID: QualifiedSourceID, repository: HostStorageRepository) {
        self.sourceID = sourceID
        self.repository = repository
    }

    func get(_ key: String) async throws -> JSONValue? {
        try Self.validateKey(key)
        return await repository.value(for: key, sourceID: sourceID)
    }

    func set(_ key: String, value: JSONValue) async throws {
        try Self.validateKey(key)
        try HostJSONValueConverter.validate(value)
        try await repository.set(value, for: key, sourceID: sourceID)
    }

    func remove(_ key: String) async throws {
        try Self.validateKey(key)
        try await repository.removeValue(for: key, sourceID: sourceID)
    }

    func keys(prefix: String) async throws -> [String] {
        if prefix.utf8.count > HostCapabilityLimits.storageKeyBytes {
            throw Self.storageError("the storage prefix exceeded the host limit")
        }
        return await repository.keys(prefix: prefix, sourceID: sourceID)
    }

    private static func validateKey(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= HostCapabilityLimits.storageKeyBytes else {
            throw storageError("the storage key is empty or exceeded the host limit")
        }
    }

    private static func storageError(_ message: String) -> HostCapabilityError {
        HostCapabilityError(code: .storage, message: message)
    }
}

actor HostStorageRepository {
    private let fileURL: URL
    private var namespaces: [String: [String: JSONValue]]

    init(directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            fileURL = directory.appendingPathComponent("extension-storage.json", isDirectory: false)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                namespaces = try Self.decode(data)
            } else {
                namespaces = [:]
            }
        } catch let error as HostCapabilityError {
            throw error
        } catch {
            throw HostCapabilityError(code: .storage,
                                      message: "Source storage could not be opened")
        }
    }

    func value(for key: String, sourceID: QualifiedSourceID) -> JSONValue? {
        namespaces[sourceID.rawValue]?[key]
    }

    func keys(prefix: String, sourceID: QualifiedSourceID) -> [String] {
        (namespaces[sourceID.rawValue] ?? [:]).keys
            .filter { $0.hasPrefix(prefix) }
            .sorted()
    }

    func set(_ value: JSONValue, for key: String, sourceID: QualifiedSourceID) throws {
        let previous = namespaces
        namespaces[sourceID.rawValue, default: [:]][key] = value
        do {
            let sourceValues = namespaces[sourceID.rawValue] ?? [:]
            guard try Self.encoded(sourceValues).count <= HostCapabilityLimits.storageTotalBytes else {
                throw HostCapabilityError(code: .storage,
                                          message: "the Source storage quota was exceeded")
            }
            try persist()
        } catch {
            namespaces = previous
            throw error
        }
    }

    func removeValue(for key: String, sourceID: QualifiedSourceID) throws {
        guard namespaces[sourceID.rawValue]?[key] != nil else { return }
        let previous = namespaces
        namespaces[sourceID.rawValue]?.removeValue(forKey: key)
        if namespaces[sourceID.rawValue]?.isEmpty == true {
            namespaces.removeValue(forKey: sourceID.rawValue)
        }
        do {
            try persist()
        } catch {
            namespaces = previous
            throw error
        }
    }

    /// Host-only administrative operation. Disablement and ordinary uninstall never
    /// call this; a reader's explicit data-removal action does.
    func eraseUserData(for sourceID: QualifiedSourceID) throws {
        guard namespaces[sourceID.rawValue] != nil else { return }
        let previous = namespaces
        namespaces.removeValue(forKey: sourceID.rawValue)
        do {
            try persist()
        } catch {
            namespaces = previous
            throw error
        }
    }

    private func persist() throws {
        do {
            let data = try Self.encoded(namespaces)
            try data.write(to: fileURL,
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch let error as HostCapabilityError {
            throw error
        } catch {
            throw HostCapabilityError(code: .storage,
                                      message: "Source storage could not be saved")
        }
    }

    private static func encoded(_ value: [String: [String: JSONValue]]) throws -> Data {
        let json = try value.mapValues { fields in
            try fields.mapValues(HostJSONValueConverter.foundationValue)
        }
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    private static func encoded(_ value: [String: JSONValue]) throws -> Data {
        let json = try value.mapValues(HostJSONValueConverter.foundationValue)
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    private static func decode(_ data: Data) throws -> [String: [String: JSONValue]] {
        let root: JSONValue
        do {
            root = try JSONValue(parsing: data)
        } catch {
            throw HostCapabilityError(code: .storage,
                                      message: "Source storage is not valid JSON")
        }
        guard case .object(let rawNamespaces) = root else {
            throw HostCapabilityError(code: .storage,
                                      message: "Source storage has an invalid root")
        }
        var decoded: [String: [String: JSONValue]] = [:]
        for (source, value) in rawNamespaces {
            guard case .object(let fields) = value else {
                throw HostCapabilityError(code: .storage,
                                          message: "a Source storage namespace is invalid")
            }
            decoded[source] = fields
        }
        return decoded
    }
}

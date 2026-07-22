//
//  FaceEnrollmentStore.swift
//  glance
//
//  Milestone E: save a person's face as a named "identity" made of one or
//  more sample embeddings, averaged into a single template vector. Persisted
//  as plain JSON in Application Support — on-device only, nothing leaves
//  the Mac.
//

import Foundation
import Observation

struct FaceIdentity: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var samples: [[Float]]
    /// Which `FaceEmbedder` produced these samples — comparing samples from
    /// two different embedders would be meaningless, so the UI can warn if
    /// this doesn't match the embedder currently in use.
    var embedderName: String

    /// The single vector actually compared against at recognition time.
    var template: [Float]? {
        FaceEmbedding.average(samples)
    }
}

@Observable
@MainActor
final class FaceEnrollmentStore {
    private(set) var identities: [FaceIdentity] = []

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("glance", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("face-identities.json")
        load()
    }

    func addSample(name: String, embedding: [Float], embedderName: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let index = identities.firstIndex(where: { $0.name == trimmed }) {
            identities[index].samples.append(embedding)
            identities[index].embedderName = embedderName
        } else {
            identities.append(FaceIdentity(id: UUID(), name: trimmed, samples: [embedding], embedderName: embedderName))
        }
        save()
    }

    func delete(_ identity: FaceIdentity) {
        identities.removeAll { $0.id == identity.id }
        save()
    }

    func deleteAll() {
        identities.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        identities = (try? JSONDecoder().decode([FaceIdentity].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(identities) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

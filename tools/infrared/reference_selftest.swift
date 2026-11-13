import Foundation

@main
struct ReferenceSelfTest {
    static func main() throws {
        func vector(_ x: Float, _ y: Float = 0) -> [Float] {
            [x, y] + [Float](repeating: 0, count: 510)
        }
        func sample(_ values: [Float], id: UUID = UUID(), model: String = "ir-test") -> InfraredFaceSample {
            InfraredFaceSample(captureID: id, modelIdentifier: model, embedding: values)
        }
        func rejects(_ reason: InfraredReferenceError, _ action: () throws -> Void) {
            do { try action(); fatalError("Expected rejection: \(reason)") }
            catch let error as InfraredReferenceError {
                precondition(String(describing: error) == String(describing: reason))
            } catch { fatalError("Unexpected error: \(error)") }
        }
        var reference = InfraredReference()
        rejects(.referenceIncomplete) { _ = try reference.compare(sample(vector(1))) }
        for values in [[], [Float](repeating: 1, count: 511), vector(0), vector(.nan), vector(.infinity)] {
            rejects(.invalidEmbedding) { try reference.add(sample(values)) }
            precondition(reference.count == 0)
        }
        let firstID = UUID()
        try reference.add(sample(vector(2), id: firstID))
        rejects(.repeatedCapture) { try reference.add(sample(vector(1), id: firstID)) }
        rejects(.differentModel) { try reference.add(sample(vector(1), model: "rgb-test")) }
        precondition(reference.count == 1)
        try reference.add(sample(vector(3)))
        rejects(.referenceIncomplete) { _ = try reference.compare(sample(vector(1))) }
        try reference.add(sample(vector(4)))
        precondition(reference.isComplete)
        rejects(.referenceFull) { try reference.add(sample(vector(1))) }
        rejects(.repeatedCapture) { _ = try reference.compare(sample(vector(1), id: firstID)) }
        rejects(.differentModel) { _ = try reference.compare(sample(vector(1), model: "other")) }
        rejects(.invalidEmbedding) { _ = try reference.compare(sample(vector(.nan))) }
        let same = try reference.compare(sample(vector(8)))
        precondition(abs(same.centroid - 1) < 1e-10)
        precondition(abs(same.minimumReference - 1) < 1e-10 && abs(same.maximumReference - 1) < 1e-10)
        let orthogonal = try reference.compare(sample(vector(0, 1)))
        precondition(abs(orthogonal.centroid) < 1e-10)
        let opposite = try reference.compare(sample(vector(-1)))
        precondition(abs(opposite.centroid + 1) < 1e-10)
        precondition(reference.count == 3) // comparisons must not train the reference
        reference.clear()
        precondition(reference.count == 0 && !reference.isComplete)
        rejects(.referenceIncomplete) { _ = try reference.compare(sample(vector(1))) }
        print("IR reference tests passed: fresh captures, model separation, invalid vectors, cosine scale, immutable comparison and clearing.")
    }
}

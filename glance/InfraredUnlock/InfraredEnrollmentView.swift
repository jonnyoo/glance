import SwiftUI
import Observation

@Observable @MainActor
private final class InfraredEnrollmentController {
    let service = InfraredServiceManager()
    private let analyzer = InfraredFaceAnalyzer()
    private(set) var image: CGImage?
    private(set) var samples: [InfraredFaceSample] = []
    private(set) var isBusy = false
    var status = "Look at the BRIO and capture three infrared reference scans."
    private var operation: Task<Void, Never>?
    private var generation = UUID()

    func capture(beforeCapture: @escaping @MainActor () async -> Void) {
        guard !isBusy, samples.count < 3 else { return }
        service.refresh()
        guard service.enabled else { status = "Enable and approve the camera helper first."; return }
        guard SecureCredentialManager.isSessionUnlocked, !LockMonitor.isScreenActuallyLocked() else {
            status = "Unlock your Mac and authenticate in Glance before enrolling."; return
        }
        isBusy = true
        image = nil
        status = "Capturing infrared…"
        let id = UUID()
        generation = id
        operation = Task {
            do {
                await beforeCapture()
                try Task.checkCancellation()
                let result = try await InfraredServiceManager.capture()
                let frame = try result.image()
                guard generation == id else { return }
                image = frame
                let sample = try await analyzer.sample(from: frame, captureID: id)
                try Task.checkCancellation()
                guard generation == id else { return }
                guard SecureCredentialManager.isSessionUnlocked, !LockMonitor.isScreenActuallyLocked() else {
                    throw SecureFaceStoreError.sessionLocked
                }
                samples.append(sample)
                status = samples.count == 3 ? "Three scans captured. Save to attach them to this identity."
                    : "Captured \(samples.count) of 3. Keep the same person in view and capture again."
            } catch {
                guard generation == id else { return }
                status = error.localizedDescription
            }
            guard generation == id else { return }
            isBusy = false
            operation = nil
        }
    }

    func clear() {
        generation = UUID()
        operation?.cancel(); operation = nil
        isBusy = false; image = nil; samples = []
    }
}

struct InfraredEnrollmentView: View {
    let identity: FaceIdentity
    let environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = InfraredEnrollmentController()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Infrared enrollment: \(identity.name)").font(.title2)
            Text("Use the same person as this identity's colour-camera enrollment. The BRIO briefly interrupts its normal video and audio during each scan.")
                .font(.callout)
            if !controller.service.enabled {
                HStack {
                    Button("Enable camera helper") { controller.service.enable() }
                        .disabled(!controller.service.available || controller.service.registered)
                    if controller.service.needsApproval {
                        Button("Open System Settings") { controller.service.openSettings() }
                    }
                    Button("Check approval") { controller.service.refresh() }
                }
                Text(controller.service.available ? controller.service.message : "This build does not include the signed infrared helper.")
                    .font(.caption)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black)
                if let image = controller.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .accessibilityLabel("Infrared enrollment preview")
                } else { Text("Infrared preview").foregroundStyle(.white) }
            }.frame(width: 340, height: 340)
            Text(controller.status).font(.callout).textSelection(.enabled)
            HStack {
                Button("Capture scan (\(controller.samples.count)/3)") {
                    controller.capture {
                        environment.faceLabController.stop()
                        await environment.faceLabController.camera.stopAndWait()
                        await environment.faceUnlockCoordinator.camera.stopAndWait()
                    }
                }.disabled(controller.isBusy || controller.samples.count == 3 || !controller.service.enabled)
                if controller.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { controller.clear(); dismiss() }
                Button("Save infrared enrollment") {
                    do {
                        let enrollment = try InfraredEnrollment(samples: controller.samples)
                        try FaceEnrollmentStore.shared.setInfrared(enrollment, for: identity)
                        controller.clear(); dismiss()
                    } catch { controller.status = error.localizedDescription }
                }.disabled(controller.isBusy || controller.samples.count != 3)
            }
            Text("Face features are encrypted with your existing enrollment. Images are not saved. Enable the additional infrared check separately in Recognition settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 640)
        .onChange(of: scenePhase) { _, phase in if phase == .active { controller.service.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.service.refresh()
        }
        .onChange(of: FaceEnrollmentStore.shared.isLocked) { _, locked in
            if locked { controller.clear(); dismiss() }
        }
        .onDisappear { controller.clear() }
    }
}

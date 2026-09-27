import SwiftUI

struct InfraredLabView: View {
    var beforeCapture: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = InfraredProbeController()

    var body: some View {
        GroupBox("Infrared camera — experimental") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Test the Logitech BRIO's infrared sensor. This test does not enable IR face unlock.")
                    .font(.callout)
                if controller.service.available {
                    Text("Enable the camera helper once to test without repeated administrator prompts. You can disable it here when finished.")
                        .font(.caption)
                    HStack {
                        if controller.service.registered {
                            Button("Disable camera helper") {
                                Task { await controller.service.disable() }
                            }
                        } else {
                            Button("Enable camera helper") { controller.service.enable() }
                        }
                        if controller.service.needsApproval {
                            Button("Open System Settings") { controller.service.openSettings() }
                        }
                        Text(controller.service.enabled ? "Enabled" : (controller.service.needsApproval ? "Awaiting approval" : "Disabled"))
                            .font(.caption)
                    }
                    .disabled(controller.isBusy)
                    if !controller.service.message.isEmpty {
                        Text(controller.service.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Check camera") { controller.check() }
                        .disabled(controller.isBusy || !controller.helperAvailable)
                    Button("Test infrared for 5 seconds") {
                        beforeCapture()
                        controller.capture()
                    }
                    .disabled(controller.isBusy || !controller.canCapture || (controller.service.available && !controller.service.enabled))
                    if controller.isBusy {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { controller.clear() }
                    }
                    Spacer()
                }
                Text(controller.helperAvailable ? controller.status : "The optional IR helper is not included in this build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.black)
                    if let image = controller.image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 340, height: 340)
                            .accessibilityLabel("Infrared camera test image")
                    } else {
                        Text(controller.isBusy ? "Waiting for the IR image…" : "Infrared image appears here after the test")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
                .frame(width: 340, height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if let statistics = controller.statistics {
                    Text(statistics).font(.caption.monospacedDigit())
                }
                Text("The test briefly interrupts BRIO video and audio. Images stay in memory and are cleared when this panel closes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.service.refresh() }
        }
        .onDisappear { controller.clear() }
    }
}

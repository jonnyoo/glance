//
//  AppLockShieldView.swift
//  glance
//
//  A native, Apple-grade Face ID biometric shield view displayed on locked apps.
//

import SwiftUI
import AppKit

enum ShieldState {
    case idle
    case verifying
    case success
    case failed
}

@Observable
final class AppLockShieldModel {
    var appName: String = ""
    var appIcon: NSImage? = nil
    var state: ShieldState = .idle
    var onTryAgain: (() -> Void)? = nil
    var onQuitApp: (() -> Void)? = nil
}

struct AppLockShieldView: View {
    var model: AppLockShieldModel
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    
    @State private var scanLineOffset: CGFloat = -26
    @State private var glowOpacity: Double = 0.4
    
    var body: some View {
        ZStack {
            // Full-screen backdrop blur
            if reduceTransparency {
                Color.black.opacity(0.85)
                    .ignoresSafeArea()
            } else {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    .ignoresSafeArea()
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
            }
            
            // Centered Glass Modal
            VStack(spacing: 28) {
                // App Icon & Name
                VStack(spacing: 14) {
                    if let icon = model.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                    } else {
                        Image(systemName: "app.fill")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 72, height: 72)
                            .foregroundColor(.gray)
                    }
                    
                    VStack(spacing: 4) {
                        Text(model.appName)
                            .font(.system(size: 22, weight: .bold, design: .default))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        
                        Text("Locked with Face ID")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                    }
                }
                
                // Biometric Scanner Center
                ZStack {
                    switch model.state {
                    case .idle, .verifying:
                        faceIDScanningView
                            .transition(.scale.combined(with: .opacity))
                    case .success:
                        faceIDSuccessView
                            .transition(.scale(scale: 1.2).combined(with: .opacity))
                    case .failed:
                        faceIDFailedView
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(height: 120)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .frame(width: 380)
            .background {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Color.black.opacity(0.65))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.25), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.5), radius: 30, y: 15)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: model.state)
    }
    
    // MARK: - Face ID Scanning State
    
    private var faceIDScanningView: some View {
        VStack(spacing: 16) {
            ZStack {
                // Background aura
                Circle()
                    .fill(Color.blue.opacity(glowOpacity * 0.35))
                    .frame(width: 80, height: 80)
                    .blur(radius: 12)
                
                // Face ID Glyphs with Laser Beam
                Image(systemName: "faceid")
                    .font(.system(size: 56, weight: .light))
                    .foregroundColor(.white.opacity(0.9))
                
                // Animated Glowing Laser Scan Line
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.cyan.opacity(0.9), Color.blue, Color.cyan.opacity(0.9), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 46, height: 2.5)
                    .shadow(color: .cyan, radius: 4)
                    .offset(y: scanLineOffset)
            }
            .frame(width: 68, height: 68)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    scanLineOffset = 26
                    glowOpacity = 0.8
                }
            }
            
            Text("Verifying Face…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
        }
    }
    
    // MARK: - Face ID Success State
    
    private var faceIDSuccessView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.25))
                    .frame(width: 72, height: 72)
                    .blur(radius: 8)
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundColor(.green)
            }
            .frame(width: 68, height: 68)
            
            Text("Unlocked")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.green)
        }
    }
    
    // MARK: - Face ID Failed State
    
    private var faceIDFailedView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.2))
                    .frame(width: 64, height: 64)
                
                Image(systemName: "faceid")
                    .font(.system(size: 48, weight: .light))
                    .foregroundColor(.red.opacity(0.9))
            }
            
            VStack(spacing: 12) {
                Text("Face Not Recognized")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.red)
                
                HStack(spacing: 12) {
                    Button(action: { model.onTryAgain?() }) {
                        Text("Try Again")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { model.onQuitApp?() }) {
                        Text("Quit App")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

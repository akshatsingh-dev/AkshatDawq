import SwiftUI

// MARK: - Onboarding gate

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var page: Int = 0
    @StateObject private var cactus = CactusManager.shared
    @StateObject private var hk = HealthKitManager.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $page) {
                WelcomePage().tag(0)
                HowItWorksPage().tag(1)
                HealthKitPage(hk: hk).tag(2)
                SetupModelPage(cactus: cactus, onFinish: { isComplete = true }).tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: page)

            // Page dots + nav
            if page < 3 {
                VStack(spacing: 20) {
                    PageDots(total: 4, current: page)
                    Button(action: advance) {
                        Text(page == 2 && !hk.isAuthorized ? "Connect Apple Health" : "Continue")
                            .font(.body.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.primary, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                    }
                    .padding(.horizontal, 24)
                    .task(id: page) { }
                }
                .padding(.bottom, 48)
                .background(
                    LinearGradient(
                        colors: [Color(uiColor: .systemBackground).opacity(0), Color(uiColor: .systemBackground)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .ignoresSafeArea()
                )
                .transition(.opacity)
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    private func advance() {
        if page == 2 {
            Task {
                try? await hk.requestAuthorization()
                withAnimation { page += 1 }
            }
        } else {
            withAnimation { page += 1 }
        }
    }
}

// MARK: - Page 1: Welcome

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Hero icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.green.opacity(0.18), .teal.opacity(0.12)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)

                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(
                        LinearGradient(colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }
            .padding(.bottom, 32)

            Text("DAWQ")
                .font(.system(size: 48, weight: .black, design: .rounded))
                .padding(.bottom, 8)

            Text("Your private health journal")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 14) {
                FeatureLine(icon: "lock.fill", color: .green,
                            title: "100% on-device",
                            subtitle: "AI runs locally. No health data ever leaves your phone.")
                FeatureLine(icon: "applewatch", color: .blue,
                            title: "Apple Watch connected",
                            subtitle: "Heart rate, HRV, sleep, steps — all pulled from HealthKit.")
                FeatureLine(icon: "mic.fill", color: .purple,
                            title: "Voice logging",
                            subtitle: "Dictate symptoms and meds in seconds. Transcribed on-device.")
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 120)
        }
    }
}

// MARK: - Page 2: How it works

private struct HowItWorksPage: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 60)

                Text("How DAWQ works")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)

                Text("Three layers, zero cloud")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 40)

                VStack(spacing: 0) {
                    FlowStep(
                        number: "1",
                        color: .blue,
                        icon: "applewatch",
                        title: "Collect",
                        subtitle: "HealthKit syncs biometrics nightly. Voice notes transcribed on-device via Whisper."
                    )
                    FlowConnector()
                    FlowStep(
                        number: "2",
                        color: .purple,
                        icon: "cpu.fill",
                        title: "Understand",
                        subtitle: "A tiny on-device model (Gemma 4B, ~2.5 GB) extracts entities and patterns from your logs."
                    )
                    FlowConnector()
                    FlowStep(
                        number: "3",
                        color: .green,
                        icon: "chart.bar.xaxis.ascending",
                        title: "Insights",
                        subtitle: "SQL math finds correlations. The model narrates results — it never invents medical facts."
                    )
                }
                .padding(.horizontal, 24)

                // Privacy callout
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                    Text("Raw data stays in SQLite on your phone. Cloud queries use an anonymized abstract only — no names, no doses, no dates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
                .padding(.top, 32)

                Spacer(minLength: 140)
            }
        }
    }
}

// MARK: - Page 3: HealthKit

private struct HealthKitPage: View {
    @ObservedObject var hk: HealthKitManager

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Apple Watch visual
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.blue.opacity(0.15), .cyan.opacity(0.1)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 120, height: 120)
                Image(systemName: "applewatch.watchface")
                    .font(.system(size: 54))
                    .foregroundStyle(LinearGradient(colors: [.blue, .cyan], startPoint: .top, endPoint: .bottom))
            }
            .padding(.bottom, 28)

            Text("Connect Apple Health")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .padding(.bottom, 8)

            Text("DAWQ reads — never writes — the following types:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 28)

            // Data types grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(DataType.allCases) { dt in
                    DataTypePill(dt: dt)
                }
            }
            .padding(.horizontal, 24)

            if hk.isAuthorized {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Apple Health connected").foregroundStyle(.green).font(.subheadline.bold())
                }
                .padding(.top, 24)
            }

            Spacer(minLength: 140)
        }
    }
}

// MARK: - Page 4: AI setup

struct SetupModelPage: View {
    @ObservedObject var cactus: CactusManager
    var onFinish: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 60)

                VStack(spacing: 4) {
                    Text("Set up on-device AI")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("DAWQ uses one default private model so you can start immediately.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.bottom, 32)

                let model = OnDeviceModel.primary
                VStack(spacing: 12) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(model.accentColor.opacity(0.12))
                                .frame(width: 44, height: 44)
                            Image(systemName: model.icon)
                                .foregroundStyle(model.accentColor)
                                .font(.system(size: 20))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .font(.subheadline.bold())
                            Text("\(model.sizeGB) GB · \(model.paramCount) · \(model.speedLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if cactus.isModelLoaded {
                            Label("Ready", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption.bold())
                        } else if let state = cactus.downloadStates[model.id] {
                            switch state {
                            case .downloading(let progress):
                                CircularProgress(progress: progress, color: model.accentColor)
                                    .frame(width: 28, height: 28)
                            case .installing:
                                ProgressView()
                            case .failed:
                                Label("Retry needed", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                        } else {
                            Text("Not downloaded")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 20)

                // Storage note
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive.fill").foregroundStyle(.secondary)
                    Text("Stored in your app's private container. Never uploaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)
                .padding(.horizontal, 24)

                // Setup / finish
                VStack(spacing: 12) {
                    if cactus.isModelLoaded {
                        Button(action: onFinish) {
                            Text("Get Started")
                                .font(.body.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(.primary, in: RoundedRectangle(cornerRadius: 14))
                                .foregroundStyle(Color(uiColor: .systemBackground))
                        }
                    }

                    Button {
                        Task { await cactus.ensureDefaultModelReady() }
                    } label: {
                        Text(cactus.isModelLoaded ? "Model is ready" : "Download and Prepare Model")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(cactus.isModelLoaded ? .green : .blue)
                    }
                    .disabled(cactus.isModelLoaded)

                    Button(action: onFinish) {
                        Text("Continue without model")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 48)
            }
        }
        .task {
            if !cactus.isModelLoaded {
                await cactus.ensureDefaultModelReady()
            }
        }
    }
}

// MARK: - ModelRow

struct ModelRow: View {
    let model: OnDeviceModel
    @ObservedObject var cactus: CactusManager

    private var isActive: Bool { cactus.activeModel?.id == model.id }
    private var downloadState: CactusManager.DownloadState? { cactus.downloadStates[model.id] }

    var body: some View {
        HStack(spacing: 14) {
            // Model icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(model.accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: model.icon)
                    .foregroundStyle(model.accentColor)
                    .font(.system(size: 20))
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.subheadline.bold())
                    if model.isNew {
                        Text("New")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                    if model.isRecommended {
                        Text("Recommended")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text("\(model.sizeGB) GB · \(model.paramCount) · \(model.speedLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Action
            Group {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                } else if let state = downloadState {
                    switch state {
                    case .downloading(let progress):
                        CircularProgress(progress: progress, color: model.accentColor)
                            .frame(width: 28, height: 28)
                    case .installing:
                        ProgressView()
                    case .failed:
                        Button("Retry") {
                            Task { await cactus.download(model) }
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                    }
                } else {
                    Button("Download") {
                        Task { await cactus.download(model) }
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(model.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(model.accentColor)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isActive ? Color.green.opacity(0.5) : .clear, lineWidth: 1.5)
        )
    }
}

// MARK: - Supporting views

private struct FeatureLine: View {
    let icon: String; let color: Color; let title: String; let subtitle: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct FlowStep: View {
    let number: String; let color: Color; let icon: String; let title: String; let subtitle: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(color.opacity(0.12)).frame(width: 44, height: 44)
                Image(systemName: icon).foregroundStyle(color).font(.system(size: 18))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

private struct FlowConnector: View {
    var body: some View {
        HStack {
            Spacer().frame(width: 22)
            Rectangle()
                .fill(.quaternary)
                .frame(width: 2, height: 20)
                .padding(.leading, 21)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

enum DataType: String, CaseIterable, Identifiable {
    case heartRate = "Heart Rate"
    case hrv = "HRV"
    case sleep = "Sleep"
    case steps = "Steps"
    case calories = "Calories"
    case spo2 = "Blood Oxygen"
    case restingHR = "Resting HR"
    case respiratory = "Respiratory"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .heartRate: return "heart.fill"
        case .hrv: return "waveform.path.ecg"
        case .sleep: return "moon.fill"
        case .steps: return "figure.walk"
        case .calories: return "flame.fill"
        case .spo2: return "lungs.fill"
        case .restingHR: return "heart.text.square.fill"
        case .respiratory: return "wind"
        }
    }
}

private struct DataTypePill: View {
    let dt: DataType
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: dt.icon).font(.caption).foregroundStyle(.blue)
            Text(dt.rawValue).font(.caption.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct PageDots: View {
    let total: Int; let current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.primary : Color.primary.opacity(0.2))
                    .frame(width: i == current ? 20 : 6, height: 6)
                    .animation(.spring(duration: 0.3), value: current)
            }
        }
    }
}

struct CircularProgress: View {
    let progress: Double; let color: Color
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: progress)
            Text("\(Int(progress * 100))")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(color)
        }
    }
}

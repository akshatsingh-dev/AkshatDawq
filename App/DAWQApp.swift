import SwiftUI
import BackgroundTasks

@main
struct DAWQApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some Scene {
        WindowGroup {
            if onboardingComplete {
                ContentView()
                    .task {
                        await CactusManager.shared.ensureDefaultModelReady()
                        NightlyBatchProcessor.shared.scheduleNextRun()
                    }
            } else {
                OnboardingView(isComplete: $onboardingComplete)
                    .transition(.opacity)
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register BGProcessingTask handler
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: NightlyBatchProcessor.taskIdentifier,
            using: nil
        ) { task in
            NightlyBatchProcessor.shared.handleBGTask(task as! BGProcessingTask)
        }
        return true
    }
}

import SwiftUI

@main
struct PromptMeetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            PromptMeetSettingsView()
        }
    }
}

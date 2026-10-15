import SwiftUI

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 18) {
                Text("Your captures stay on your Mac.").font(.title2.bold())
                Text("Easyshot is published by Paraply Ventures AS. It does not require an account, include advertising or analytics, or send your screenshots, recordings, recognized text, or settings to our servers.")
                Text("Screen access").font(.headline)
                Text("You choose what to capture. macOS requests Screen Recording permission before capture. Microphone and camera access are optional and requested only when you enable those recording features. A visible control bar shows when recording is active.")
                Text("Files and clipboard").font(.headline)
                Text("Captures and history are stored locally. When clipboard copying is enabled, your capture is placed on the macOS clipboard, where other apps may read it. Files you share, paste, or save in a cloud-synced folder are handled by the apps and services you choose.")
                if CloudSession.isAvailable {
                    Text("Easyshot Cloud (optional)").font(.headline)
                    Text("Nothing leaves your Mac unless you sign in and choose to upload. When you do, only that screenshot, your account email and a hashed session are sent to the Easyshot server, which stores the image privately and shows it to anyone who has its link for 30 days. Delete an upload from the Cloud page at any time; expired uploads are removed automatically.")
                }
                Text("Control your data").font(.headline)
                Text("Change the save folder and clipboard behavior in Settings. Removing a capture from history does not delete its file. Delete saved captures in Finder when you no longer need them. macOS permissions can be revoked in System Settings → Privacy & Security.")
            }.padding(28)
        }.frame(minWidth: 500,minHeight: 420)
    }
}

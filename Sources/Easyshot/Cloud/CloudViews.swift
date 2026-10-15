import SwiftUI
import AppKit
import EasyshotCore

/// Sign in (password or emailed code) / create account / reset password / confirm email / sign out.
struct CloudAccountForm: View {
    /// `confirm` finishes a new or unconfirmed account with the code the server emailed.
    private enum Mode { case password, code, reset, confirm }
    @ObservedObject var cloud = CloudSession.shared
    @ObservedObject var preferences = Preferences.shared
    @State private var mode = Mode.password
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var newPassword = ""
    @State private var codeSent = false
    @State private var notice: String?
    @State private var showServer = false
    private func switchTo(_ new: Mode) { mode = new; codeSent = false; code = ""; newPassword = ""; notice = nil; cloud.error = nil }
    var body: some View {
        if cloud.isSignedIn { signedIn } else { signedOut }
    }
    @ViewBuilder private var signedIn: some View {
        HStack {
            Label(cloud.user?.email ?? "Signed in",systemImage: cloud.user?.emailVerified == false ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle.badge.checkmark")
            Spacer()
            Button("Sign Out") { cloud.signOut() }
        }
        if cloud.user?.emailVerified == false {
            Text("Confirm your email address to keep your account safe and recover it if you forget your password.").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("6-digit code",text: $code).frame(width: 110).onSubmit { confirm() }
                Button("Confirm") { confirm() }.disabled(cloud.busy || code.count < 6)
                Button("Send Code") { Task { notice = await cloud.sendVerification() ? "Code sent. Check your inbox." : nil } }.disabled(cloud.busy)
            }
            status
        }
    }
    private func confirm() { Task { if await cloud.confirmEmail(code: code) { code = ""; notice = "Email confirmed." } } }
    @ViewBuilder private var status: some View {
        if let error = cloud.error { Text(error).font(.caption).foregroundStyle(.red) }
        else if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
    }
    @ViewBuilder private var signedOut: some View {
        TextField("Email",text: $email).textContentType(.username)
        switch mode {
        case .password:
            SecureField("Password",text: $password).textContentType(.password)
                .onSubmit { passwordSignIn(register: false) }
            HStack {
                Button("Sign In") { passwordSignIn(register: false) }
                    .buttonStyle(.glassProminent).disabled(cloud.busy)
                Button("Create Account") { passwordSignIn(register: true) }.disabled(cloud.busy)
                if cloud.busy { ProgressView().controlSize(.small) }
            }
            HStack {
                Button("Email me a sign-in code") { switchTo(.code) }
                Button("Forgot password?") { switchTo(.reset) }
            }.buttonStyle(.link).font(.caption)
        case .code:
            codeFields(sendTitle: "Email Me a Code",confirmTitle: "Sign In") { Task { await cloud.signIn(email: email,code: code) } }
        case .confirm:
            Text("Enter the code we emailed to \(email) to finish signing in. If this address already has an account, the code signs you in to it.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("6-digit code from the email",text: $code).onSubmit { confirmAccount() }
            HStack {
                Button("Confirm",action: confirmAccount).buttonStyle(.glassProminent).disabled(cloud.busy || code.count < 6)
                // Registering again mails a fresh code tied to this password; the server answers the same either way.
                Button("Resend Code") { Task { if await cloud.signIn(email: email,password: password,register: true) { notice = "A new code is on its way." } } }
                    .buttonStyle(.glass).disabled(cloud.busy)
                Button("Back") { switchTo(.password) }.buttonStyle(.link)
                if cloud.busy { ProgressView().controlSize(.small) }
            }
        case .reset:
            codeFields(sendTitle: "Email Reset Code",confirmTitle: "Reset Password",newPassword: true) {
                Task { if await cloud.resetPassword(email: email,code: code,newPassword: newPassword) { switchTo(.password); notice = "Password changed. Sign in with the new one." } }
            }
        }
        status
        DisclosureGroup("Server",isExpanded: $showServer) {
            // Locked while a request is in flight, so an answer can't be mistaken for the new server's.
            TextField("https://…",text: $preferences.cloudBaseURL).textFieldStyle(.roundedBorder)
                .onSubmit { cloud.serverChanged() }.disabled(cloud.busy)
            Text("Passwords need at least 10 characters. Screenshots are kept for 30 days.").font(.caption).foregroundStyle(.secondary)
        }.font(.callout)
    }
    private func passwordSignIn(register: Bool) {
        Task {
            guard await cloud.signIn(email: email,password: password,register: register) else { return }
            switchTo(.confirm); notice = "Check your email for a 6-digit code."
        }
    }
    private func confirmAccount() { Task { await cloud.signIn(email: email,code: code) } }
    @ViewBuilder private func codeFields(sendTitle: String,confirmTitle: String,newPassword needsPassword: Bool = false,action: @escaping () -> Void) -> some View {
        if codeSent {
            TextField("6-digit code from the email",text: $code).onSubmit { if !needsPassword { action() } }
            if needsPassword { SecureField("New password (10+ characters)",text: $newPassword).textContentType(.newPassword).onSubmit(action) }
        }
        HStack {
            if codeSent {
                Button(confirmTitle,action: action).buttonStyle(.glassProminent).disabled(cloud.busy || code.count < 6 || (needsPassword && newPassword.isEmpty))
            }
            Button(codeSent ? "Resend Code" : sendTitle) {
                Task { if await cloud.requestCode(email: email,reset: needsPassword) { codeSent = true; notice = "If that account exists, a code is on its way." } }
            }
            .buttonStyle(.glass).disabled(cloud.busy)
            Button("Back") { switchTo(.password) }.buttonStyle(.link)
            if cloud.busy { ProgressView().controlSize(.small) }
        }
    }
}

struct UploadKeyRow: View {
    @ObservedObject var preferences = Preferences.shared
    var body: some View {
        HStack {
            Text("Upload key")
            Spacer()
            TextField("u",text: Binding(get: { preferences.uploadKey },set: { preferences.uploadKey = CaptureKeyAction.sanitizedUploadKey($0.isEmpty ? "" : String($0.suffix(1))) }))
                .frame(width: 40).multilineTextAlignment(.center).textFieldStyle(.roundedBorder)
        }
        Text("In the capture bar, press \(preferences.uploadKey.uppercased()) or ⇧Return to capture, upload and copy a link. For a system-wide shortcut, give the Raycast command “Paste as Link” a hotkey: it turns the image on your clipboard into a link you can paste over SSH.")
            .font(.caption).foregroundStyle(.secondary)
        Toggle("Record & Share: copy the link when recording starts",isOn: $preferences.shareCopyLinkAtStart)
        Toggle("Record & Share: transcribe my voice on this Mac",isOn: $preferences.shareTranscribe)
        Text("Record & Share uploads while you record, so the link plays the moment you stop. Captions are made on device from the microphone and uploaded as WebVTT.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// Settings rows for Easyshot Cloud: account and the capture-bar upload key.
struct CloudSettingsSection: View {
    @ObservedObject var preferences = Preferences.shared
    @ObservedObject var cloud = CloudSession.shared
    var body: some View {
        Section("Easyshot Cloud") {
            CloudAccountForm()
            UploadKeyRow()
        }
    }
}

@MainActor final class CloudLibraryModel: ObservableObject {
    @Published var items: [CloudScreenshot] = []
    @Published var loading = false
    @Published var error: String?
    @Published var hasMore = false
    private var cursor: String?
    func reload() async { cursor = nil; items = []; await more() }
    func more() async {
        let cloud = CloudSession.shared
        guard !loading,let client = cloud.client else { return }
        loading = true; error = nil; defer { loading = false }
        do {
            let page = try await client.list(before: cursor)
            items += page.items.filter { new in !items.contains { $0.id == new.id } }
            cursor = page.next; hasMore = page.next != nil
        } catch CloudError.notSignedIn { cloud.sessionExpired() }
        catch { self.error = error.localizedDescription }
    }
    func delete(_ item: CloudScreenshot) async {
        do { try await CloudSession.shared.client?.delete(item.id); items.removeAll { $0.id == item.id } }
        catch { self.error = error.localizedDescription }
    }
}

struct CloudLibraryPage: View {
    @ObservedObject var controller: AppController
    @ObservedObject var cloud = CloudSession.shared
    @StateObject private var model = CloudLibraryModel()
    var body: some View {
        VStack(alignment: .leading,spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                Text("Links that travel.").font(.system(size: 28,weight: .semibold)).tracking(-0.8)
                Spacer()
                if cloud.isSignedIn {
                    Button { Task { await model.reload() } } label: { Label("Refresh",systemImage: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 11))
                }
            }
            Text("Uploaded screenshots are private to you and stay available through their link for 30 days.").font(.system(size: 12)).foregroundStyle(.secondary)
            if !cloud.isSignedIn {
                Form { Section("Sign in") { CloudAccountForm() } }.formStyle(.grouped).frame(maxWidth: 440).scrollDisabled(true)
            } else {
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
                let sections = CloudLibrary.sections(model.items,date: \.createdAt)
                if sections.isEmpty && !model.loading {
                    VStack(spacing: 9) {
                        Image(systemName: "icloud.and.arrow.up").font(.system(size: 27,weight: .ultraLight)).foregroundStyle(.white.opacity(0.22))
                        Text("Nothing uploaded yet").font(.system(size: 12,weight: .medium)).foregroundStyle(.white.opacity(0.65))
                        Text("Press U in the capture bar, or use Paste as Link, to share a screenshot as a link.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                    }.frame(maxWidth: .infinity).padding(.vertical,30)
                }
                ForEach(sections,id: \.title) { section in
                    VStack(alignment: .leading,spacing: 12) {
                        Text(section.title.uppercased()).font(.system(size: 9,weight: .semibold)).tracking(1.4).foregroundStyle(.white.opacity(0.4))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(),spacing: 14),count: 3),spacing: 14) {
                            ForEach(section.items) { item in CloudCard(item: item,controller: controller,model: model) }
                        }
                    }
                }
                if model.hasMore { Button("Load more") { Task { await model.more() } }.disabled(model.loading) }
                else if model.loading { ProgressView().controlSize(.small) }
            }
        }.task(id: cloud.isSignedIn) { if cloud.isSignedIn { await model.reload(); await cloud.refreshUser() } }
    }
}

struct CloudCard: View {
    let item: CloudScreenshot
    @ObservedObject var controller: AppController
    @ObservedObject var model: CloudLibraryModel
    var body: some View {
        VStack(alignment: .leading,spacing: 0) {
            ZStack {
                Color.white.opacity(0.035)
                AsyncImage(url: URL(string: item.imageURL)) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit().padding(12)
                    case .failure: Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                    default: ProgressView().controlSize(.small)
                    }
                }
            }.frame(height: 135).clipped().contentShape(Rectangle()).onTapGesture { open() }
            HStack {
                VStack(alignment: .leading,spacing: 5) {
                    Text(item.createdAt,format: .dateTime.hour().minute()).font(.system(size: 11,weight: .medium))
                    Text(CloudLibrary.expiryText(item.expiresAt)).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { if controller.copyLink(item.shareURL) { controller.status = "Link copied" } } label: { Image(systemName: "link").font(.system(size: 11)) }.buttonStyle(.plain).help("Copy link")
                Menu {
                    Button("Copy link") { _ = controller.copyLink(item.shareURL) }
                    Button("Open in browser") { open() }
                    Divider()
                    Button("Delete from cloud",role: .destructive) { Task { await model.delete(item) } }
                } label: { Image(systemName: "ellipsis").font(.system(size: 11)) }.menuStyle(.borderlessButton).fixedSize()
            }.padding(12)
        }.background(.white.opacity(0.025),in: RoundedRectangle(cornerRadius: 10)).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.06)))
    }
    func open() { if let url = ShareLink.validated(item.shareURL) { NSWorkspace.shared.open(url) } }
}

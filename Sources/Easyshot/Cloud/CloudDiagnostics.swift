import AppKit
import EasyshotCore

/// `Easyshot --cloud-test https://host` registers a throwaway account and exercises the whole upload path.
enum CloudDiagnostics {
    static func run(base: String) async -> Int32 {
        var failures = 0
        func check(_ ok: Bool,_ name: String) { print(ok ? "PASS: \(name)" : "FAIL: \(name)"); if !ok { failures += 1 } }
        guard let url = Preferences.validatedServerURL(base) else { print("FAIL: invalid server URL"); return 1 }
        do {
            let email = "cloud-test-\(UUID().uuidString.prefix(8).lowercased())@example.com"
            let auth = try await CloudClient(baseURL: url).authenticate(register: true,email: email,password: "correct horse battery staple",deviceName: "cloud-test")
            check(auth.user.email == email,"register returns the new user")
            let client = CloudClient(baseURL: url,token: auth.token)
            check((try await client.me()).email == email,"session token authenticates /v1/me")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: 64,pixelsHigh: 48,bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0)!
            let png = rep.representation(using: .png,properties: [:])!
            let image = try UploadableImage.make(data: png,contentType: "image/png",rep: rep,filename: "test.png")
            let created = try await client.create(contentType: image.contentType,byteSize: image.data.count,width: image.width,height: image.height,filename: image.filename)
            try await client.put(image.data,to: created)
            let done = try await client.complete(created.screenshot.id)
            check(ShareLink.validated(done.shareURL) != nil,"upload completes with a share link")
            check(done.expiresAt.timeIntervalSinceNow > 29 * 86_400,"screenshots expire about 30 days out")
            let page = try await client.list()
            check(page.items.contains { $0.id == done.id },"upload appears in the library")
            var request = URLRequest(url: ShareLink.validated(done.shareURL)!)
            request.setValue("Easyshot-test",forHTTPHeaderField: "User-Agent")
            let (bytes,response) = try await URLSession.shared.data(for: request)
            check((response as? HTTPURLResponse)?.statusCode == 200 && bytes == png,"anonymous share link serves the original bytes")
            try await client.delete(done.id)
            let after = try await client.list()
            check(!after.items.contains { $0.id == done.id },"deleted upload leaves the library")
            await client.logout()
            do { _ = try await client.me(); check(false,"logged-out token is rejected") } catch CloudError.notSignedIn { check(true,"logged-out token is rejected") }
        } catch { print("FAIL: \(error.localizedDescription)"); failures += 1 }
        print(failures == 0 ? "CLOUD TEST PASSED" : "CLOUD TEST FAILED")
        return failures == 0 ? 0 : 1
    }
}

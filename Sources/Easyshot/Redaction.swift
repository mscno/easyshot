import AppKit
import CryptoKit
import ImageIO
import Vision
import EasyshotCore

/// On-device text analysis shared by the editor (highlighter snapping, crop snapping, secret
/// detection) and the pre-upload check. Rectangles are image pixels with a bottom-left origin.
struct TextAnalysis: Sendable {
    struct Secret: Sendable,Equatable { var rect: CGRect; var kind: SecretScanner.Kind; var text: String }
    var lines: [CGRect] = []
    var secrets: [Secret] = []

    static func analyze(_ image: CGImage,scanner: SecretScanner) async throws -> TextAnalysis {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // Keys and tokens are not words; correction would "fix" them into different strings.
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image,options: [:]).perform([request])
            let w = CGFloat(image.width),h = CGFloat(image.height)
            func pixels(_ box: CGRect) -> CGRect { CGRect(x: box.minX*w,y: box.minY*h,width: box.width*w,height: box.height*h) }
            var result = TextAnalysis()
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                result.lines.append(pixels(observation.boundingBox))
                let string = candidate.string
                for match in scanner.scan(string) {
                    // Vision locates whole words. For a secret inside a longer token (KEY=sk-…), narrow the
                    // token's box by character position, widened by half a character so no edge escapes.
                    var token = match.range
                    while token.lowerBound > string.startIndex,!string[string.index(before: token.lowerBound)].isWhitespace { token = string.index(before: token.lowerBound)..<token.upperBound }
                    while token.upperBound < string.endIndex,!string[token.upperBound].isWhitespace { token = token.lowerBound..<string.index(after: token.upperBound) }
                    guard var box = try? candidate.boundingBox(for: token)?.boundingBox else { continue }
                    if token != match.range {
                        let count = CGFloat(string.distance(from: token.lowerBound,to: token.upperBound))
                        let a = (CGFloat(string.distance(from: token.lowerBound,to: match.range.lowerBound))-0.5)/count
                        let b = (CGFloat(string.distance(from: token.lowerBound,to: match.range.upperBound))+0.5)/count
                        box = CGRect(x: box.minX+box.width*max(0,a),y: box.minY,width: box.width*(min(1,b)-max(0,a)),height: box.height)
                    }
                    let rect = pixels(box).insetBy(dx: -3,dy: -3).intersection(CGRect(x: 0,y: 0,width: w,height: h))
                    if !rect.isNull { result.secrets.append(Secret(rect: rect.integral,kind: match.kind,text: match.text)) }
                }
            }
            return result
        }.value
    }
}

enum Redaction {
    /// Solid black boxes; unlike blur or mosaics, nothing of the original survives.
    static func apply(_ image: CGImage,boxes: [CGRect]) -> CGImage? {
        guard let ctx = EditorModel.context(width: image.width,height: image.height) else { return nil }
        ctx.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
        ctx.setFillColor(NSColor.black.cgColor); ctx.fill(boxes)
        return ctx.makeImage()
    }
    static func summary(_ secrets: [TextAnalysis.Secret]) -> String {
        var counts: [String: Int] = [:]
        for secret in secrets { counts[secret.kind.title,default: 0] += 1 }
        return counts.sorted { $0.key < $1.key }.map { "\($0.value) × \($0.key)" }.joined(separator: ", ")
    }
    /// What the pre-upload check concluded. Only `.clean` uploads without asking; an image that could
    /// not be checked is never treated as clean.
    enum Scan {
        case clean
        /// Findings in a single still image, which can be blacked out.
        case secrets(CGImage,[TextAnalysis.Secret])
        /// Findings in an animation, which cannot be redacted frame by frame.
        case animated([TextAnalysis.Secret],frames: Int)
        case unscanned(String)
    }
    /// With "Redact secrets before upload" on, looks for secrets and lets the user redact them,
    /// upload unchanged, or cancel (nil). Images without findings pass straight through.
    @MainActor static func reviewBeforeUpload(_ upload: UploadableImage) async throws -> UploadableImage? {
        guard Preferences.shared.redactBeforeUpload else { return upload }
        let alert = NSAlert()
        switch try await scan(upload) {
        case .clean: return upload
        case .secrets(let image,let secrets):
            alert.messageText = "This image may contain secrets"
            alert.informativeText = "Easyshot found \(summary(secrets)). Redact them before the link is created?"
            alert.addButton(withTitle: "Redact and Upload"); alert.addButton(withTitle: "Upload Unchanged"); alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            switch alert.runModal() {
            case .alertFirstButtonReturn: return try redacted(upload,image: image,secrets: secrets)
            case .alertSecondButtonReturn: return upload
            default: return nil
            }
        case .animated(let secrets,let frames):
            alert.messageText = "This animation may contain secrets"
            alert.informativeText = "Easyshot found \(summary(secrets)) in \(frames) frames. Animations can't be redacted automatically; upload it anyway?"
        case .unscanned(let reason):
            alert.messageText = "This image couldn't be checked for secrets"
            alert.informativeText = "\(reason) Upload it anyway?"
        }
        alert.addButton(withTitle: "Upload Unchanged"); alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? upload : nil
    }
    /// OCRs every frame of the exact bytes being uploaded; the declared content type plays no part.
    @MainActor static func scan(_ upload: UploadableImage) async throws -> Scan {
        let scanner = Preferences.shared.secretScanner
        guard let source = CGImageSourceCreateWithData(upload.data as CFData,nil),CGImageSourceGetCount(source) > 0 else { return .unscanned("Easyshot could not decode it.") }
        let count = CGImageSourceGetCount(source)
        guard count <= UploadImageType.maxScannedFrames else { return .unscanned("It has \(count) frames, more than Easyshot checks (\(UploadImageType.maxScannedFrames)).") }
        var findings: [TextAnalysis.Secret] = [],frames = 0,first: CGImage?,seen = Set<SHA256.Digest>()
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source,index,nil) else { return .unscanned("Frame \(index+1) could not be decoded.") }
            if index == 0 { first = image }
            // Screen recordings repeat frames; OCR each distinct one once.
            if count > 1,let pixels = image.dataProvider?.data,!seen.insert(SHA256.hash(data: pixels as Data)).inserted { continue }
            let secrets = try await TextAnalysis.analyze(image,scanner: scanner).secrets
            if !secrets.isEmpty { findings += secrets; frames += 1 }
        }
        if findings.isEmpty { return .clean }
        if count == 1,let first { return .secrets(first,findings) }
        return .animated(findings,frames: frames)
    }
    static func redacted(_ upload: UploadableImage,image: CGImage,secrets: [TextAnalysis.Secret]) throws -> UploadableImage {
        // Vision boxes are bottom-left; CGContext fills use the same origin.
        guard let redacted = apply(image,boxes: secrets.map(\.rect)) else { throw ShotError.message("Could not redact this image.") }
        let png = try ScreenshotPixels.png(redacted)
        guard let rep = NSBitmapImageRep(data: png) else { throw ShotError.message("Could not encode the redacted image.") }
        return try UploadableImage.make(data: png,contentType: "image/png",rep: rep,filename: ((upload.filename as NSString).deletingPathExtension)+".png")
    }
}

import AppKit
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
                for match in scanner.scan(candidate.string) {
                    guard let box = try? candidate.boundingBox(for: match.range)?.boundingBox else { continue }
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
    /// With "Redact secrets before upload" on, looks for secrets and lets the user redact them,
    /// upload unchanged, or cancel (nil). Images without findings pass straight through.
    @MainActor static func reviewBeforeUpload(_ upload: UploadableImage) async throws -> UploadableImage? {
        let p = Preferences.shared
        guard p.redactBeforeUpload,upload.contentType != "image/gif",
              let source = CGImageSourceCreateWithData(upload.data as CFData,nil),let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { return upload }
        let secrets = try await TextAnalysis.analyze(image,scanner: p.secretScanner).secrets
        guard !secrets.isEmpty else { return upload }
        let alert = NSAlert()
        alert.messageText = "This image may contain secrets"
        alert.informativeText = "Easyshot found \(summary(secrets)). Redact them before the link is created?"
        alert.addButton(withTitle: "Redact and Upload"); alert.addButton(withTitle: "Upload Unchanged"); alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Vision boxes are bottom-left; CGContext fills use the same origin.
            guard let redacted = apply(image,boxes: secrets.map(\.rect)) else { throw ShotError.message("Could not redact this image.") }
            let png = try ScreenshotPixels.png(redacted)
            guard let rep = NSBitmapImageRep(data: png) else { throw ShotError.message("Could not encode the redacted image.") }
            return try UploadableImage.make(data: png,contentType: "image/png",rep: rep,filename: ((upload.filename as NSString).deletingPathExtension)+".png")
        case .alertSecondButtonReturn: return upload
        default: return nil
        }
    }
}

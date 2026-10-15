import CoreGraphics

enum ScrollStitcher {
    /// Match moving content at the bottom of the previous viewport to the top of the next.
    static func overlap(_ first: CGImage,_ second: CGImage) -> Int? {
        guard first.width == second.width,let a = pixels(first),let b = pixels(second) else { return nil }
        let height = min(first.height,second.height)
        guard height > 60 else { return nil }
        var best: (Int,Double)?
        let samplesX = stride(from: max(2,first.width/20),to: first.width-max(2,first.width/20),by: max(1,first.width/32))
        for overlap in 24...height {
            var error = 0.0; var count = 0
            for y in stride(from: 0,to: overlap,by: max(1,overlap/28)) {
                for x in samplesX {
                    let ai = ((first.height-overlap+y)*first.width+x)*4
                    let bi = (y*second.width+x)*4
                    for c in 0..<3 { error += Double(abs(Int(a[ai+c])-Int(b[bi+c]))); count += 1 }
                }
            }
            let mean = error/Double(max(count,1))
            if mean < (best?.1 ?? .infinity)-0.1 || (abs(mean-(best?.1 ?? .infinity)) < 0.1 && overlap > (best?.0 ?? 0)) { best = (overlap,mean) }
        }
        guard let best,best.1 < 10 else { return nil }
        return best.0
    }
    static func stitch(_ frames: [CGImage]) throws -> CGImage {
        guard let first = frames.first else { throw ShotError.message("Add at least one frame.") }
        var total = first.height
        var overlaps: [Int] = [0]
        for i in 1..<frames.count {
            guard let overlap = overlap(frames[i-1],frames[i]) else { throw ShotError.message("Frames \(i) and \(i+1) do not overlap. Scroll less between frames and exclude fixed headers from your area.") }
            overlaps.append(overlap); total += frames[i].height-overlap
        }
        guard let ctx = EditorModel.context(width: first.width,height: total) else { throw ShotError.message("Scrolling capture is too large. Finish with fewer frames.") }
        var top = total
        for (i,frame) in frames.enumerated() {
            let remaining = frame.height-overlaps[i]
            if remaining == 0 { continue }
            let part = i == 0 ? frame : frame.cropping(to: CGRect(x: 0,y: overlaps[i],width: frame.width,height: remaining))
            guard let part else { throw ShotError.message("Could not crop scrolling frame.") }
            top -= remaining
            ctx.draw(part,in: CGRect(x: 0,y: top,width: first.width,height: remaining))
        }
        guard let result = ctx.makeImage() else { throw ShotError.message("Could not combine frames.") }
        return result
    }
    private static func pixels(_ image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0,count: image.width*image.height*4)
        let success = bytes.withUnsafeMutableBytes { pointer -> Bool in
            guard let ctx = CGContext(data: pointer.baseAddress,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height)); return true
        }
        return success ? bytes : nil
    }
}

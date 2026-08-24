// 生成 DSH Desktop 应用图标（白底黑鲸）— 用户本机可靠版
// 用法: swift make-icon.swift <whale.svg|png> <iconset目录> <菜单栏模板png输出>
// 用显式 CGBitmapContext + 纯白 sRGB 底 + 黑鲸，规避深色模式下 NSColor.white 变黑。
// 黑鲸优先从矢量 SVG 渲染（NSImage 支持 SVG，无损放大到 1024），
// 避免旧 50px 源图放大 20 倍导致的模糊；PNG 仅作后备。
import AppKit
import CoreGraphics
import ImageIO

guard CommandLine.arguments.count >= 4 else {
    FileHandle.standardError.write("usage: make-icon.swift <whale.svg|png> <iconset> <menubar.png>\n".data(using: .utf8)!)
    exit(1)
}
let srcPath = CommandLine.arguments[1]
let outputDir = CommandLine.arguments[2]
let menubarPng = CommandLine.arguments[3]

// 矢量 SVG（NSImage 原生支持 SVG，可无损放大）优先；PNG 作为后备
let whaleImage = NSImage(contentsOfFile: srcPath)
guard whaleImage != nil || FileManager.default.fileExists(atPath: srcPath) else {
    FileHandle.standardError.write("cannot load \(srcPath)\n".data(using: .utf8)!)
    exit(1)
}
var srcCG: CGImage? = nil
if let isrc = CGImageSourceCreateWithURL(URL(fileURLWithPath: srcPath) as CFURL, nil) {
    srcCG = CGImageSourceCreateImageAtIndex(isrc, 0, nil)
}
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let specs: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

// 在上下文中心绘制黑鲸（等比；SVG 内容实际占绘制框 ~97%×73%，
// 绘制框 0.62s 时黑鲸约占白底面积 40%，饱满但不过满）；SVG 走矢量，PNG 走插值后备
func drawWhale(in ctx: CGContext, size s: CGFloat) {
    let box = s * 0.62
    let rect = CGRect(x: (s-box)/2, y: (s-box)/2, width: box, height: box)
    if let img = whaleImage {
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
    } else if let cg = srcCG {
        let sw = CGFloat(cg.width), sh = CGFloat(cg.height)
        let sc = min(box/sw, box/sh)
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: (s-sw*sc)/2, y: (s-sh*sc)/2, width: sw*sc, height: sh*sc))
    }
}

func render(size: Int) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    let bytes = size*size*4
    guard let buf = calloc(bytes, 1) else { return nil }
    defer { free(buf) }   // 注意：makeImage 后（本机 ImageIO 正常）CGImage 会自持有拷贝
    guard let ctx = CGContext(data: buf, width: size, height: size,
                             bitsPerComponent: 8, bytesPerRow: size*4,
                             space: cs, bitmapInfo: info) else { return nil }
    let s = CGFloat(size)
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
    // 纯白圆角底（sRGB 1,1,1，规避深色 NSColor 变黑）
    // 内容占画布 ~82%（Apple 图标规范：824/1024，四边留 ~9% margin），
    // 使 Dock 渲染尺寸与其他系统应用一致（此前 91% 导致磁贴偏大）
    let inset = s * 0.09
    let shape = CGPath(roundedRect: CGRect(x: inset, y: inset, width: s-inset*2, height: s-inset*2),
                       cornerWidth: s*0.21, cornerHeight: s*0.21, transform: nil)
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()
    drawWhale(in: ctx, size: s)
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        FileHandle.standardError.write("failed to write \(path)\n".data(using: .utf8)!)
        exit(1)
    }
}

for spec in specs {
    guard let img = render(size: spec.size) else {
        FileHandle.standardError.write("failed render \(spec.name)\n".data(using: .utf8)!)
        exit(1)
    }
    writePNG(img, to: "\(outputDir)/\(spec.name)")
    print("wrote \(spec.name)")
}

// 菜单栏模板：透明黑鲸
let ms = 36
let mcs = CGColorSpaceCreateDeviceRGB()
let minfo = CGImageAlphaInfo.premultipliedLast.rawValue
if let mbuf = calloc(ms*ms*4, 1) {
    let mctx = CGContext(data: mbuf, width: ms, height: ms, bitsPerComponent: 8,
                         bytesPerRow: ms*4, space: mcs, bitmapInfo: minfo)!
    mctx.clear(CGRect(x: 0, y: 0, width: ms, height: ms))
    if let img = whaleImage {
        let nsCtx = NSGraphicsContext(cgContext: mctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        let box: CGFloat = 20
        img.draw(in: CGRect(x: (CGFloat(ms)-box)/2, y: (CGFloat(ms)-box)/2, width: box, height: box),
                 from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
    } else if let cg = srcCG {
        let sw = CGFloat(cg.width), sh = CGFloat(cg.height)
        let sc = min(20.0/sw, 20.0/sh)
        mctx.draw(cg, in: CGRect(x: (CGFloat(ms)-sw*sc)/2, y: (CGFloat(ms)-sh*sc)/2, width: sw*sc, height: sh*sc))
    }
    if let mg = mctx.makeImage() { writePNG(mg, to: menubarPng) }
    free(mbuf)
}
print("menubar template written")

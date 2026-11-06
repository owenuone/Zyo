// 生成菜单栏模板图标：swift Scripts/make_icon.swift Resources/icon.tiff
// 16pt 水滴头部剪影（字游吉祥物，源文件 design/ziyou/）：实心头部，脸窗镂空，两只眼睛；输出 1x、2x，另加 4x 供设置窗口放大显示
import AppKit

let output = CommandLine.arguments[1]

func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

// 坐标照搬 design/ziyou/app-icon-small.svg（240×240，y 向下），最后统一变换到 16pt
func headPath() -> NSBezierPath {
    let head = NSBezierPath()
    head.move(to: pt(150, 18))
    head.curve(to: pt(86, 54), controlPoint1: pt(126, 34), controlPoint2: pt(106, 44))
    head.curve(to: pt(36, 140), controlPoint1: pt(54, 72), controlPoint2: pt(36, 104))
    head.curve(to: pt(118, 214), controlPoint1: pt(36, 186), controlPoint2: pt(72, 214))
    head.curve(to: pt(200, 140), controlPoint1: pt(164, 214), controlPoint2: pt(200, 186))
    head.curve(to: pt(164, 68), controlPoint1: pt(200, 108), controlPoint2: pt(184, 84))
    head.curve(to: pt(150, 18), controlPoint1: pt(150, 56), controlPoint2: pt(144, 40))
    head.close()

    // 脸窗与头部合成一条路径，用奇偶规则镂空
    head.move(to: pt(58, 132))
    head.curve(to: pt(94, 109), controlPoint1: pt(58, 110), controlPoint2: pt(76, 104))
    head.curve(to: pt(142, 109), controlPoint1: pt(108, 113), controlPoint2: pt(128, 113))
    head.curve(to: pt(178, 132), controlPoint1: pt(160, 104), controlPoint2: pt(178, 110))
    head.line(to: pt(178, 156))
    head.curve(to: pt(118, 192), controlPoint1: pt(178, 180), controlPoint2: pt(158, 192))
    head.curve(to: pt(58, 156), controlPoint1: pt(78, 192), controlPoint2: pt(58, 180))
    head.close()
    head.windingRule = .evenOdd
    return head
}

func eyePaths() -> [NSBezierPath] {
    [92, 144].map { cx in NSBezierPath(ovalIn: NSRect(x: cx - 16, y: 148 - 19, width: 32, height: 38)) }
}

// 头部外框 x 36…200、y 18…214：缩放到高 15.4pt，水平居中，并把 y 轴翻成向上
func toIcon() -> AffineTransform {
    let s: CGFloat = 15.4 / 196
    var t = AffineTransform(translationByX: 8 - 118 * s, byY: 16 - 0.3 + 18 * s)
    t.scale(x: s, y: -s)
    return t
}

func makeRep(scale: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(16 * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: 16, height: 16)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.setFill()
    for path in [headPath()] + eyePaths() {
        path.transform(using: toIcon())
        path.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: NSSize(width: 16, height: 16))
image.addRepresentation(makeRep(scale: 1))
image.addRepresentation(makeRep(scale: 2))
image.addRepresentation(makeRep(scale: 4))
try! image.tiffRepresentation!.write(to: URL(fileURLWithPath: output))

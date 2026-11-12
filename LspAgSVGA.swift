import UIKit
import zlib

// SVGA 2.x protobuf 读取、动画模型、路径构建和 UIKit 播放。
// 解码器是同步入口，由上层放到后台任务执行；UIView 绘制、播放状态和 SwiftUI 协调在主执行器处理。
// 当前实现覆盖项目使用的 SVGA 2.x 子集：音频只保存字节，不在这里播放，也没有 matte 合成或 1.x JSON 解码。

// MARK: - 协议缓冲读取

/// SVGA 的 `.svga` 文件是 zlib 压缩的 protobuf（`com.opensource.svga`）。
///
/// 这里只实现解析需要的 wire format 子集：varint、fixed32（float）、
/// length-delimited（string / bytes / 嵌套 message）。不引入 protobuf 运行时，
/// 因为 schema 固定且字段很少。
struct LspAgProtoReader {
    /// 转为零起点字节数组，统一索引与边界计算，不依赖原始 Data 是否为切片。
    private let bytes: [UInt8]
    /// 下一次读取的位置；每个读取方法都负责推进，发生错误时直接移到末尾。
    private(set) var index: Int
    /// 一旦遇到截断、溢出或不支持的 wire type 就保持失败，交由外层解析器抛错。
    /// 将索引移到末尾同时终止字段循环，避免损坏数据导致重复读取或死循环。
    private(set) var isInvalid = false

    init(_ data: Data) {
        bytes = [UInt8](data)
        index = 0
    }

    /// 只表示没有剩余字节；正常结束和失败都可能为 true，必须结合 isInvalid 判断。
    var isAtEnd: Bool { index >= bytes.count }

    /// protobuf 每字节携带 7 位；UInt64 的第 10 个字节只能是 0 或 1。
    /// 返回 0 只是失败时的占位值，调用者必须通过 `isInvalid` 区分合法的零。
    mutating func readVarint() -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift <= 63 {
            let byte = bytes[index]
            index += 1
            guard shift < 63 || byte <= 1 else { isInvalid = true; index = bytes.count; return 0 }
            // 低 7 位拼接到结果，高位 0x80 表示后面还有字节；不能把符号位当作数值。
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        isInvalid = true
        index = bytes.count
        return 0
    }

    /// 长度和整数字段最终需要用于 Swift 下标，不能直接将任意 UInt64 强转为 Int。
    mutating func readInt() -> Int {
        let value = readVarint()
        guard let result = Int(exactly: value) else { isInvalid = true; index = bytes.count; return 0 }
        return result
    }

    /// 返回 (字段号, wire type)；正常读到末尾返回 nil。
    /// 非法 tag 也返回 nil，但会设置 `isInvalid`，供所属 message 的解析器检查。
    mutating func nextTag() -> (field: Int, wire: Int)? {
        guard !isAtEnd else { return nil }
        let tag = readVarint()
        // tag = 字段号 << 3 | wire type。字段 0、超范围字段及不支持的 group 编码均视为错误。
        guard !isInvalid, tag >> 3 > 0, tag >> 3 <= 0x1FFF_FFFF,
              [0, 1, 2, 5].contains(Int(tag & 0x7)), let field = Int(exactly: tag >> 3) else {
            isInvalid = true; index = bytes.count; return nil
        }
        return (field, Int(tag & 0x7))
    }

    /// fixed32 按小端逐字节组装为 IEEE 754 Float，再提升为 Double 供绘制使用。
    /// 不直接从 Data 强制读取 UInt32，避免未对齐内存访问；NaN / 无穷值不能进入几何计算。
    mutating func readFloat() -> Double {
        guard bytes.count - index >= 4 else { isInvalid = true; index = bytes.count; return 0 }
        var value: UInt32 = 0
        for offset in 0..<4 {
            value |= UInt32(bytes[index + offset]) << (8 * UInt32(offset))
        }
        index += 4
        let number = Double(Float(bitPattern: value))
        guard number.isFinite else { isInvalid = true; index = bytes.count; return 0 }
        return number
    }

    /// 先验证声明长度不超过剩余字节，再计算结束位置；零长度是合法字段。
    mutating func readBytes() -> Data {
        let length = readInt()
        guard !isInvalid, length <= bytes.count - index else {
            isInvalid = true
            index = bytes.count
            return Data()
        }
        guard length > 0 else { return Data() }
        let slice = Data(bytes[index..<(index + length)])
        index += length
        return slice
    }

    /// 字符串同样先读长度；无效 UTF-8 标记为错误，合法空字符串仍保留为空值。
    mutating func readString() -> String {
        guard let value = String(data: readBytes(), encoding: .utf8) else {
            isInvalid = true; index = bytes.count; return ""
        }
        return value
    }

    /// 跳过当前不使用的字段以兼容 schema 扩展，同时对各 wire type 做边界检查。
    mutating func skip(wire: Int) {
        switch wire {
        case 0: _ = readVarint()
        case 1:
            guard bytes.count - index >= 8 else { isInvalid = true; index = bytes.count; return }
            index += 8
        case 2: _ = readBytes()
        case 5:
            guard bytes.count - index >= 4 else { isInvalid = true; index = bytes.count; return }
            index += 4
        default: isInvalid = true; index = bytes.count
        }
    }
}

// MARK: - 模型

/// 文件画布及时间轴参数。画布尺寸是动画逻辑坐标，不是屏幕尺寸或当前 UIView 的尺寸。
public struct LspAgSVGAParams: Equatable, Sendable {
    public internal(set) var viewBoxWidth: Double = 0
    public internal(set) var viewBoxHeight: Double = 0
    public internal(set) var fps: Int = 20
    public internal(set) var frames: Int = 0

    /// 未设置或手工构造为非正数时按 20 fps 计算；正式 decode 还会校验允许的参数范围。
    public var effectiveFPS: Int { fps > 0 ? fps : 20 }
    /// 一轮动画的估算时长；未校验模型也至少按一帧计算，不能用此值代替可播放性校验。
    public var duration: TimeInterval { effectiveFPS > 0 ? Double(max(frames, 1)) / Double(effectiveFPS) : 0 }
}

/// 保留原始 layout 字段。当前图片目标矩形从局部坐标 (0, 0) 开始，平移使用 frame transform。
public struct LspAgSVGALayout: Equatable, Sendable {
    var x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0
}

/// 与 CGAffineTransform 对应的二维矩阵：a / b / c / d 表示线性变换，tx / ty 表示平移。
/// 本地模型默认单位矩阵；可选 transform 为 nil 时表示文件没有提供这一层变换。
public struct LspAgSVGATransform: Equatable, Sendable {
    var a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, tx: Double = 0, ty: Double = 0

    var affine: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
    var isIdentity: Bool { self == LspAgSVGATransform() }
}

/// 保存文件中的 RGBA 浮点分量，正常资源使用 0...1；透明度还会与所在帧的 alpha 相乘。
public struct LspAgSVGAColor: Equatable, Sendable {
    var r: Double = 0, g: Double = 0, b: Double = 0, a: Double = 0

    /// `frameAlpha` 与自身 alpha 相乘，对应 painter.dart 的 `Color.fromARGB(fill.a * frameAlpha, ...)`。
    func uiColor(frameAlpha: Double) -> UIColor {
        UIColor(red: r, green: g, blue: b, alpha: a * frameAlpha)
    }
}

/// 当前绘制器使用的填充 / 描边子集。可选颜色为 nil 与明确指定透明色含义不同。
/// lineDash 按现有解析顺序收集并传给 CGContext，不代表已经实现全部 SVGA 描边样式语义。
public struct LspAgSVGAStyle: Equatable, Sendable {
    var fill: LspAgSVGAColor?
    var stroke: LspAgSVGAColor?
    var strokeWidth: Double = 0
    var miterLimit: Double = 0
    public internal(set) var lineDash: [Double] = []
}

/// 文件中的形状几何。KEEP 是预处理标记，本身不参与最终绘制。
public enum LspAgSVGAShapeKind: Equatable, Sendable {
    case path(String)
    case rect(x: Double, y: Double, width: Double, height: Double, cornerRadius: Double)
    case ellipse(cx: Double, cy: Double, rx: Double, ry: Double)
    case keep
    case empty
}

/// 一个形状由几何、样式、可选局部变换组成；形状变换叠加在所在 sprite 的帧变换之后。
public struct LspAgSVGAShape: Equatable, Sendable {
    public internal(set) var kind: LspAgSVGAShapeKind = .empty
    public internal(set) var style = LspAgSVGAStyle()
    var transform: LspAgSVGATransform?
}

/// 单个 sprite 在某一帧的内容；同一帧既可以画位图，也可以在位图上继续画矢量形状。
/// alpha 缺省为 1，clipPath 在应用帧变换后裁剪该 sprite 的图片和所有形状。
public struct LspAgSVGAFrame: Equatable, Sendable {
    var alpha: Double = 1
    var layout = LspAgSVGALayout()
    var transform: LspAgSVGATransform?
    public internal(set) var clipPath: String = ""
    public internal(set) var shapes: [LspAgSVGAShape] = []
}

/// 一个按时间变化的图层。sprites 的数组顺序决定绘制顺序，不按 imageKey 排序。
public struct LspAgSVGASprite: Equatable, Sendable {
    /// 用于从 movie.images 查位图；纯形状图层也可能有 key 但没有对应位图。
    public internal(set) var imageKey: String = ""
    public internal(set) var frames: [LspAgSVGAFrame] = []

    /// 取当前帧；越界时回退到最后一帧，避免短动画在长 sprite 上闪空。
    func frame(at index: Int) -> LspAgSVGAFrame? {
        guard !frames.isEmpty else { return nil }
        return frames[min(max(index, 0), frames.count - 1)]
    }
}

/// 解析后的动画，原始图片已构造成 UIImage，播放时无需重新读取资源文件。
/// UIKit 仍可能在显示阶段准备位图；这里不承诺 UIImage(data:) 已完成全部像素解码。
/// @unchecked Sendable 用于跨后台解析任务传递结果；调用方应将已发布结果作为资源快照使用，
/// 不要在不同执行器共享并修改其中的引用对象。普通模型和数组本身采用值语义。
public struct LspAgSVGAMovie: @unchecked Sendable {
    public internal(set) var version: String = ""
    public internal(set) var params = LspAgSVGAParams()
    public internal(set) var sprites: [LspAgSVGASprite] = []
    public internal(set) var images: [String: UIImage] = [:]
    /// 音频资源（mp3）原样保留；尚未实现音频时间轴、播放或与视频帧同步。
    public internal(set) var audios: [String: Data] = [:]

    /// 供上层布局参考；手工构造的无尺寸模型返回 1，正式文件由 decode 校验尺寸。
    public var aspectRatio: CGFloat {
        guard params.viewBoxWidth > 0, params.viewBoxHeight > 0 else { return 1 }
        return CGFloat(params.viewBoxWidth / params.viewBoxHeight)
    }
}

// MARK: - 解析

/// 解析层错误，不直接决定礼物队列是否继续；SwiftUI 包装层将加载失败汇入完成回调。
/// decodeFailed 预留图片失败描述，当前 parseMovie 对无法构造 UIImage 的单项资源直接跳过。
public enum LspAgSVGAError: LocalizedError {
    case inflateFailed
    case invalidMovie
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .inflateFailed: "SVGA decompression failed."
        case .invalidMovie: "SVGA movie is missing parameters."
        case .decodeFailed(let key): "SVGA image decode failed: \(key)"
        }
    }
}

/// 对应 `plugins/svga_player` 的 `SVGAParser`。
///
/// 流程与 Flutter 一致：zlib 解压 → 解析 `MovieEntity` → 把 `images` 里的
/// `mp3` 分到音频、其余解码成位图 → 处理 `KEEP` 形状继承。
/// 这些方法不切换执行器；调用方负责后台调度，避免在 SwiftUI 更新或主线程直接解析大文件。
public enum LspAgSVGAParser {
    /// 只返回可播放的电影：必须有正数帧和画布尺寸，帧率 / 帧数需落在支持范围。
    /// 零帧率保留给 `effectiveFPS` 使用默认值；KEEP 形状在校验后统一继承。
    public static func decode(_ data: Data) throws -> LspAgSVGAMovie {
        let inflated = try inflate(data)
        var movie = try parseMovie(inflated)
        guard movie.params.frames > 0, movie.params.frames <= Int32.max,
              movie.params.fps >= 0, movie.params.fps <= Int32.max,
              movie.params.viewBoxWidth > 0, movie.params.viewBoxHeight > 0 else {
            throw LspAgSVGAError.invalidMovie
        }
        movie.sprites = movie.sprites.map(inheritingKeepShapes)
        return movie
    }

    // MARK: zlib

    /// SVGA 使用带头部和校验和的 zlib；兼容此前 Compression 生成的裸 deflate。
    /// 按 64 KB 块解压，输入与解压结果各限制为 64 MB，防止异常资源持续膨胀。
    /// 只有 zlib 返回 STREAM_END 且输入已消费完毕才视为成功；输出缓冲区填满时
    /// 继续读取。压缩流截断、校验和错误或后面附带额外数据时返回失败。
    static func inflate(_ data: Data) throws -> Data {
        let maximumInflatedSize = 64 * 1024 * 1024
        guard !data.isEmpty, data.count <= maximumInflatedSize else { throw LspAgSVGAError.inflateFailed }
        // 根据 zlib 头部的压缩方法及校验规则选择带头模式；否则按裸 deflate 处理。
        let header = [UInt8](data.prefix(2))
        let wrapped = header.count == 2 && header[0] & 0x0F == 8 &&
            (Int(header[0]) * 256 + Int(header[1])) % 31 == 0
        var stream = z_stream()
        guard inflateInit2_(&stream, wrapped ? MAX_WBITS : -MAX_WBITS,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw LspAgSVGAError.inflateFailed
        }
        // 正窗口位数验证 zlib 包装，负值只处理裸 deflate；无论成功或抛错都释放 zlib 内部状态。
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { source in
            // 整个解压循环都位于输入 Data 的借用范围内，zlib 不持有闭包外的输入地址。
            // 输入已限制为 64 MiB，因此长度可安全转换为 zlib 的 uInt。
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress!)
            stream.avail_in = uInt(data.count)
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let previousInput = stream.avail_in
                let (status, written) = buffer.withUnsafeMutableBufferPointer { destination in
                    // 每轮重置输出指针与剩余容量，written 是本轮实际产出的字节数。
                    stream.next_out = destination.baseAddress!
                    stream.avail_out = uInt(destination.count)
                    let status = zlib.inflate(&stream, Z_NO_FLUSH)
                    return (status, destination.count - Int(stream.avail_out))
                }
                // 先用减法比较剩余预算，再追加，避免容量相加溢出或先分配后发现超限。
                guard result.count <= maximumInflatedSize - written else { throw LspAgSVGAError.inflateFailed }
                result.append(contentsOf: buffer.prefix(written))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw LspAgSVGAError.inflateFailed }
                    return result
                }
                // 未到流末尾但既没有消费输入也没有产生输出，说明无法继续解压。
                guard status == Z_OK, written > 0 || stream.avail_in < previousInput else {
                    throw LspAgSVGAError.inflateFailed
                }
            }
        }
    }

    // MARK: MovieEntity

    /// 每层嵌套 message 都单独检查 reader 的错误状态，避免内层截断被当成空字段。
    private static func parseMovie(_ data: Data) throws -> LspAgSVGAMovie {
        var movie = LspAgSVGAMovie()
        var reader = LspAgProtoReader(data)
        var rawImages: [String: Data] = [:]

        while let tag = reader.nextTag() {
            switch (tag.field, tag.wire) {
            case (1, 2):
                movie.version = reader.readString()
            case (2, 2):
                movie.params = try parseParams(reader.readBytes())
            case (3, 2):
                // map<string, bytes>：一条记录是「key + value」的嵌套 message。
                try parseImageEntry(reader.readBytes(), into: &rawImages)
            case (4, 2):
                movie.sprites.append(try parseSprite(reader.readBytes()))
            case (5, 2):
                try parseAudio(reader.readBytes(), into: &movie)
            default:
                reader.skip(wire: tag.wire)
            }
        }

        guard !reader.isInvalid else { throw LspAgSVGAError.invalidMovie }
        // 图片 map 在全部 message 读取完后统一分流，字段顺序不影响 MP3 内容填充。
        // 单张图片解码失败不会使整部动画失败，其余 sprite / shape 仍可继续绘制。
        for (key, bytes) in rawImages {
            if isMP3(bytes) {
                movie.audios[key] = bytes
            } else if let image = UIImage(data: bytes) {
                movie.images[key] = image
            }
        }
        return movie
    }

    /// MovieParams：fixed32 画布宽高，varint 帧率和总帧数；最终可播放性由 decode 统一校验。
    private static func parseParams(_ data: Data) throws -> LspAgSVGAParams {
        var params = LspAgSVGAParams()
        var reader = LspAgProtoReader(data)
        while let tag = reader.nextTag() {
            switch (tag.field, tag.wire) {
            case (1, 5): params.viewBoxWidth = reader.readFloat()
            case (2, 5): params.viewBoxHeight = reader.readFloat()
            case (3, 0): params.fps = reader.readInt()
            case (4, 0): params.frames = reader.readInt()
            default: reader.skip(wire: tag.wire)
            }
        }
        guard !reader.isInvalid else { throw LspAgSVGAError.invalidMovie }
        return params
    }

    /// protobuf 的 map 实际是重复的 entry message，字段 1 是 key，字段 2 是二进制内容。
    /// 相同 key 按后出现的值覆盖；空 key 不进入资源字典。
    private static func parseImageEntry(_ data: Data, into images: inout [String: Data]) throws {
        var reader = LspAgProtoReader(data)
        var key = ""
        var value = Data()
        while let tag = reader.nextTag() {
            switch (tag.field, tag.wire) {
            case (1, 2): key = reader.readString()
            case (2, 2): value = reader.readBytes()
            default: reader.skip(wire: tag.wire)
            }
        }
        guard !reader.isInvalid else { throw LspAgSVGAError.invalidMovie }
        if !key.isEmpty { images[key] = value }
    }

    /// 当前只保留 AudioEntity 的资源 key，不解析开始 / 结束帧等音频播放信息。
    /// 字节内容仍由 images map 提供，这里用空 Data 占位，避免与资源内容存储重复。
    private static func parseAudio(_ data: Data, into movie: inout LspAgSVGAMovie) throws {
        var reader = LspAgProtoReader(data)
        var key = ""
        while let tag = reader.nextTag() {
            switch (tag.field, tag.wire) {
            case (1, 2): key = reader.readString()
            default: reader.skip(wire: tag.wire)
            }
        }
        guard !reader.isInvalid else { throw LspAgSVGAError.invalidMovie }
        // 音频内容在 images 里（key 相同），这里只记录引用，避免重复拷贝。
        if !key.isEmpty { movie.audios[key] = movie.audios[key] ?? Data() }
    }

    /// SpriteEntity 的 key 与帧数组；逐帧保留输入顺序，不在这里扩展或补齐帧数。
    private static func parseSprite(_ data: Data) throws -> LspAgSVGASprite {
        var sprite = LspAgSVGASprite()
        var reader = LspAgProtoReader(data)
        while let tag = reader.nextTag() {
            switch (tag.field, tag.wire) {
            case (1, 2): sprite.imageKey = reader.readString()
            case (2, 2): sprite.frames.append(try parseFrame(reader.readBytes()))
            default: reader.skip(wire: tag.wire)
            }
        }
        guard !reader.isInvalid else { throw LspAgSVGAError.invalidMovie }
        return sprite
    }

    /// 解析单帧布局、变换、裁剪和形状。内层解析抛错时向上传播，不返回半成品帧。
    private static func parseFrame(_ data: Data) throws -> LspAgSVGAFrame {
        var frame = LspAgSVGAFrame()
        var reader = LspAgProtoReader(data)
        while let tag = reader.nextTag() {
            switch (tag.field, tag.wire) {
            case (1, 5): frame.alpha = reader.readFloat()
            case (2, 2): frame.layout = try parseLayout(reader.readBytes())
            case (3, 2): frame.transform = try parseTransform(reader.readBytes())
            case (4, 2): frame.clipPath = reader.readString()
            case (5, 2): frame.shapes.append(try parseShape(reader.readBytes()))
            default: reader.skip(wire: tag.wire)
            }
        }
        guard !reader.isInvalid else { throw LspAgSVGAError.invalidMovie }
        return frame
    }

    /// 固定字段号与 schema 一一对应；即使当前 painter 不使用 x / y，也保留原始字段。
    private static func parseLayout(_ data: Data) throws -> LspAgSVGALayout {
        var layout = LspAgSVGALayout()
        var reader = LspAgProtoReader(data)
        while let tag = reader.nextTag() {
            switch (tag.field, tag.wire) {
            case (1, 5): layout.x = reader.readFloat()
            case (2, 5): layout.y = reader.readFloat()
            case (3, 5): layout.width = reader.readFloat()
            case (4, 5): layout.height = reader.readFloat()
            default: reader.skip(wire: tag.wire)
            }
        }
        guard !reader.isInvalid else { throw LspAgSVGAError.invalidMovie }
        return layout
    }

    /// 读取二维矩阵，不在解析阶段预先变换几何，方便每帧组合 frame / shape 两级变换。
    private static func parseTransform(_ data: Data) throws -> LspAgSVGATransform {
        var transform = LspAgSVGATransform()
        var reader = LspAgProtoReader(data)
        while let tag = reader.nextTag() {
            switch (tag.field, tag.wire) {
            case (1, 5): transform.a = reader.readFloat()
            case (2, 5): transform.b = reader.readFloat()
            case (3, 5): transform.c = reader.readFloat()
            case (4, 5): transform.d = reader.readFloat()
            case (5, 5): transform.tx = reader.readFloat()
            case (6, 5): transform.ty = reader.readFloat()
            default: reader.skip(wire: tag.wire)
            }
        }
        guard !reader.isInvalid else { throw LspAgSVGAError.invalidMovie }
        return transform
    }

    /// ShapeEntity 的 oneof 分支：路径字符串、圆角矩形或椭圆，外加样式和局部变换。
    /// type == 3 最后统一改为 KEEP；这种标记随后由 inheritingKeepShapes 处理。
    private static func parseShape(_ data: Data) throws -> LspAgSVGAShape {
        var shape = LspAgSVGAShape()
        var reader = LspAgProtoReader(data)
        var type: Int = 0
        while let tag = reader.nextTag() {
            switch (tag.field, tag.wire) {
            case (1, 0): type = reader.readInt()
            case (2, 2):
                // ShapeArgs { string d = 1; }
                var args = LspAgProtoReader(reader.readBytes())
                while let sub = args.nextTag() {
                    if sub.field == 1, sub.wire == 2 { shape.kind = .path(args.readString()) }
                    else { args.skip(wire: sub.wire) }
                }
                guard !args.isInvalid else { throw LspAgSVGAError.invalidMovie }
            case (3, 2):
                var args = LspAgProtoReader(reader.readBytes())
                var x = 0.0, y = 0.0, w = 0.0, h = 0.0, r = 0.0
                while let sub = args.nextTag() {
                    switch (sub.field, sub.wire) {
                    case (1, 5): x = args.readFloat()
                    case (2, 5): y = args.readFloat()
                    case (3, 5): w = args.readFloat()
                    case (4, 5): h = args.readFloat()
                    case (5, 5): r = args.readFloat()
                    default: args.skip(wire: sub.wire)
                    }
                }
                guard !args.isInvalid else { throw LspAgSVGAError.invalidMovie }
                shape.kind = .rect(x: x, y: y, width: w, height: h, cornerRadius: r)
            case (4, 2):
                var args = LspAgProtoReader(reader.readBytes())
                var cx = 0.0, cy = 0.0, rx = 0.0, ry = 0.0
                while let sub = args.nextTag() {
                    switch (sub.field, sub.wire) {
                    case (1, 5): cx = args.readFloat()
                    case (2, 5): cy = args.readFloat()
                    case (3, 5): rx = args.readFloat()
                    case (4, 5): ry = args.readFloat()
                    default: args.skip(wire: sub.wire)
                    }
                }
                guard !args.isInvalid else { throw LspAgSVGAError.invalidMovie }
                shape.kind = .ellipse(cx: cx, cy: cy, rx: rx, ry: ry)
            case (10, 2): shape.style = try parseStyle(reader.readBytes())
            case (11, 2): shape.transform = try parseTransform(reader.readBytes())
            default: reader.skip(wire: tag.wire)
            }
        }
        guard !reader.isInvalid else { throw LspAgSVGAError.invalidMovie }
        // `type` 只用来区分 keep；其余类型已由 oneof 里的 args 决定。
        if type == 3 { shape.kind = .keep }
        return shape
    }

    /// 只读取当前 painter 支持的样式字段；未使用的线帽 / 连接等字段通过 skip 保持可继续解析。
    private static func parseStyle(_ data: Data) throws -> LspAgSVGAStyle {
        var style = LspAgSVGAStyle()
        var reader = LspAgProtoReader(data)
        while let tag = reader.nextTag() {
            switch (tag.field, tag.wire) {
            case (1, 2): style.fill = try parseColor(reader.readBytes())
            case (2, 2): style.stroke = try parseColor(reader.readBytes())
            case (3, 5): style.strokeWidth = reader.readFloat()
            case (6, 5): style.miterLimit = reader.readFloat()
            case (7, 5): style.lineDash.append(reader.readFloat())
            case (8, 5): style.lineDash.append(reader.readFloat())
            case (9, 5): style.lineDash.append(reader.readFloat())
            default: reader.skip(wire: tag.wire)
            }
        }
        guard !reader.isInvalid else { throw LspAgSVGAError.invalidMovie }
        return style
    }

    /// 四个 fixed32 分量依次对应 RGBA。缺失分量沿用模型默认值，不在这里补成不透明色。
    private static func parseColor(_ data: Data) throws -> LspAgSVGAColor {
        var color = LspAgSVGAColor()
        var reader = LspAgProtoReader(data)
        while let tag = reader.nextTag() {
            switch (tag.field, tag.wire) {
            case (1, 5): color.r = reader.readFloat()
            case (2, 5): color.g = reader.readFloat()
            case (3, 5): color.b = reader.readFloat()
            case (4, 5): color.a = reader.readFloat()
            default: reader.skip(wire: tag.wire)
            }
        }
        guard !reader.isInvalid else { throw LspAgSVGAError.invalidMovie }
        return color
    }

    /// `KEEP` 表示「沿用上一帧的形状」，对应 `_processShapeItems`。
    /// 具体沿用最近记录的非空形状列表：空帧跳过而不清空记录；只检查首个形状是否为 KEEP。
    /// 预处理后播放器无需每次绘制都回查历史帧；没有可继承列表的 KEEP 仍由绘制器跳过。
    private static func inheritingKeepShapes(_ sprite: LspAgSVGASprite) -> LspAgSVGASprite {
        var sprite = sprite
        var lastShapes: [LspAgSVGAShape] = []
        for index in sprite.frames.indices {
            let shapes = sprite.frames[index].shapes
            guard let first = shapes.first else { continue }
            if first.kind == .keep, !lastShapes.isEmpty {
                sprite.frames[index].shapes = lastShapes
            } else {
                lastShapes = shapes
            }
        }
        return sprite
    }

    /// 与 Flutter `isMP3Data` 一致：ID3 头或 MPEG 帧同步字。
    /// 只用于资源分流，不是完整的 MP3 文件有效性校验。
    static func isMP3(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 3, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 { return true }
        if bytes.count >= 2, bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 { return true }
        return false
    }
}

// MARK: - 路径

/// SVG path data → `UIBezierPath`，覆盖 painter.dart 支持的 M/L/H/V/C/S/Q/T/Z 及其相对形式。
/// 只负责几何，不把颜色、描边宽度或 CGContext 变换写进缓存；相同路径可被不同帧复用。
enum LspAgSVGAPath {
    /// 路径解析开销不小（一条 path 字符串要切词 + 建曲线），缓存起来复用。
    /// 缓存字典的读写全部在 lock 内；保存 CGPath，避免把可变 UIBezierPath 作为共享缓存暴露。
    nonisolated(unsafe) private static var cache: [String: CGPath] = [:]
    private static let lock = NSLock()
    /// 数字作为完整 token 匹配，保留 1e-3、+10、.5 及 10-20 这类紧邻数字的含义。
    /// 指令字母与数字分组区分，因此数字中的 e / E 不会被逐字符误当成新指令。
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"([A-Za-z])|([-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?)"#
    )

    /// 命中时用缓存 CGPath 创建独立 UIBezierPath，调用者修改返回值不会污染下一次绘制。
    /// 构建放在锁外，允许并发请求偶尔重复计算同一路径，避免复杂解析长时间占锁。
    static func path(_ d: String) -> UIBezierPath {
        lock.lock()
        if let cached = cache[d] { lock.unlock(); return UIBezierPath(cgPath: cached) }
        lock.unlock()

        let path = build(d)
        lock.lock()
        // 轻量阈值淘汰：超过阈值时整批清空，不是按最近访问顺序维护的 LRU 缓存。
        if cache.count > 256 { cache.removeAll(keepingCapacity: true) }
        cache[d] = path.cgPath
        lock.unlock()
        return path
    }

    /// 将已拆成单组参数的指令转为几何；小写坐标相对于 current，大写坐标直接使用。
    private static func build(_ d: String) -> UIBezierPath {
        let path = UIBezierPath()
        /// 当前终点，以及当前子路径的起点。Z 后相对指令必须从子路径起点继续。
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        /// 分别记录三次 / 二次曲线控制点；S / T 只在对应前序曲线存在时执行镜像。
        var lastControl: CGPoint?
        var lastQuadControl: CGPoint?

        for command in tokenize(d) {
            let values = command.values
            switch command.letter {
            case "M", "m":
                guard values.count >= 2 else { continue }
                current = command.letter == "m" ? CGPoint(x: current.x + values[0], y: current.y + values[1]) : CGPoint(x: values[0], y: values[1])
                path.move(to: current)
                subpathStart = current
                lastControl = nil; lastQuadControl = nil
            case "L", "l":
                guard values.count >= 2 else { continue }
                current = command.letter == "l" ? CGPoint(x: current.x + values[0], y: current.y + values[1]) : CGPoint(x: values[0], y: values[1])
                path.addLine(to: current)
                lastControl = nil; lastQuadControl = nil
            case "H", "h":
                guard let value = values.first else { continue }
                current.x = command.letter == "h" ? current.x + value : value
                path.addLine(to: current)
                // 直线打断曲线连续性，之后的 S / T 不应反射更早的控制点。
                lastControl = nil; lastQuadControl = nil
            case "V", "v":
                guard let value = values.first else { continue }
                current.y = command.letter == "v" ? current.y + value : value
                path.addLine(to: current)
                lastControl = nil; lastQuadControl = nil
            case "C", "c":
                guard values.count >= 6 else { continue }
                let relative = command.letter == "c"
                // 相对曲线的两个控制点和终点都相对于本条指令开始时的 current。
                let c1 = relative ? CGPoint(x: current.x + values[0], y: current.y + values[1]) : CGPoint(x: values[0], y: values[1])
                let c2 = relative ? CGPoint(x: current.x + values[2], y: current.y + values[3]) : CGPoint(x: values[2], y: values[3])
                let end = relative ? CGPoint(x: current.x + values[4], y: current.y + values[5]) : CGPoint(x: values[4], y: values[5])
                path.addCurve(to: end, controlPoint1: c1, controlPoint2: c2)
                lastControl = c2; current = end; lastQuadControl = nil
            case "S", "s":
                guard values.count >= 4 else { continue }
                let relative = command.letter == "s"
                // 关于当前终点镜像上一个三次控制点；没有合法前序控制点时直接使用当前点。
                let reflected = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = relative ? CGPoint(x: current.x + values[0], y: current.y + values[1]) : CGPoint(x: values[0], y: values[1])
                let end = relative ? CGPoint(x: current.x + values[2], y: current.y + values[3]) : CGPoint(x: values[2], y: values[3])
                path.addCurve(to: end, controlPoint1: reflected, controlPoint2: c2)
                lastControl = c2; current = end; lastQuadControl = nil
            case "Q", "q":
                guard values.count >= 4 else { continue }
                let relative = command.letter == "q"
                let control = relative ? CGPoint(x: current.x + values[0], y: current.y + values[1]) : CGPoint(x: values[0], y: values[1])
                let end = relative ? CGPoint(x: current.x + values[2], y: current.y + values[3]) : CGPoint(x: values[2], y: values[3])
                path.addQuadCurve(to: end, controlPoint: control)
                lastQuadControl = control; current = end; lastControl = nil
            case "T", "t":
                guard values.count >= 2 else { continue }
                let relative = command.letter == "t"
                // 二次曲线的平滑缩写，与 S 使用的三次曲线控制点独立维护。
                let control = lastQuadControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let end = relative ? CGPoint(x: current.x + values[0], y: current.y + values[1]) : CGPoint(x: values[0], y: values[1])
                path.addQuadCurve(to: end, controlPoint: control)
                lastQuadControl = control; current = end; lastControl = nil
            case "Z", "z":
                // 真正添加闭合边，而不是只移动坐标；这会影响填充、描边及裁剪结果。
                path.close()
                current = subpathStart
                lastControl = nil; lastQuadControl = nil
            default:
                break
            }
        }
        return path
    }

    /// 把一个字母后的多组参数拆成多条单组指令，简化 build 的相对坐标推进。
    /// 当前是支持子集的宽松读取，不是完整 SVG 语法校验；未知指令和不足一组的参数会被跳过。
    private static func tokenize(_ d: String) -> [(letter: String, values: [Double])] {
        var result: [(String, [Double])] = []
        var letter = ""
        var values: [Double] = []

        func flush() {
            // arity 是一组指令所需的标量数。Z 没有参数，也必须显式保留。
            let arity: Int
            switch letter.uppercased() {
            case "Z": result.append((letter, [])); values.removeAll(); return
            case "M", "L", "T": arity = 2
            case "H", "V": arity = 1
            case "C": arity = 6
            case "S", "Q": arity = 4
            default: values.removeAll(); return
            }
            var index = 0
            while values.count - index >= arity {
                // M 后的额外坐标是隐式 L，且相对坐标要基于上一个终点继续计算。
                let command = letter.uppercased() == "M" && index > 0 ? (letter == "m" ? "l" : "L") : letter
                result.append((command, Array(values[index..<(index + arity)])))
                index += arity
            }
            values.removeAll()
        }

        let text = d as NSString
        // NSRegularExpression 的 range 使用 UTF-16 偏移，切片统一交给 NSString，避免索引混用。
        for match in tokenPattern.matches(in: d, range: NSRange(location: 0, length: text.length)) {
            if match.range(at: 1).location != NSNotFound {
                flush()
                letter = text.substring(with: match.range(at: 1))
            } else {
                // 拒绝无穷值进入路径坐标；无法表示的数值使整条路径返回空指令列表。
                guard let number = Double(text.substring(with: match.range(at: 2))), number.isFinite else { return [] }
                values.append(number)
            }
        }
        flush()
        return result
    }
}

// MARK: - 播放器

/// CADisplayLink 强持有 target；通过弱引用中转，避免未挂到窗口的播放器形成循环引用。
@MainActor
private final class LspAgSVGADisplayTarget: NSObject {
    /// link 保留本 target，但 target 不保留 UIView，避免 run loop -> link -> view 的循环。
    weak var player: LspAgSVGAPlayerView?
    init(player: LspAgSVGAPlayerView) { self.player = player }
    @objc func tick(_ link: CADisplayLink) {
        // 即使 UIView 从未进入窗口就被释放，下一次 tick 也能自行注销遗留 link。
        guard let player else { link.invalidate(); return }
        player.tick()
    }
}

/// 对应 `SVGAAnimationController` + `SVGAImage`。
///
/// 用 `CADisplayLink` 按 fps 推进帧号，`draw(_:)` 里按 painter.dart 的顺序
/// 画：viewBox 缩放 → sprite transform → clip → 图片 → 形状。
public final class LspAgSVGAPlayerView: UIView {
    /// 更换资源时先停止旧 display link，再重置帧和清屏状态，防止旧动画继续驱动新资源。
    public var movie: LspAgSVGAMovie? {
        didSet {
            stop()
            currentFrame = 0
            isCleared = false
            setNeedsDisplay()
            invalidateIntrinsicContentSize()
        }
    }
    /// 循环播放不会触发自然结束回调；非循环播放到末帧后触发一次完成回调。
    public var loop = false
    /// 停止时是否隐藏绘制内容；为 false 时保留当前帧，供需要停留末帧的场景使用。
    public var clearsAfterStop = true
    /// 礼物通话场景按比例铺满视口，超出的部分由播放器裁剪。
    public var fillsBounds = false {
        didSet { if fillsBounds != oldValue { setNeedsDisplay() } }
    }
    /// 非循环动画播完或遇到不可播放参数时调用；手动 stop 不触发该回调。
    public var onComplete: (() -> Void)?

    /// 帧驱动是否运行；与 movie 是否仍被保留、画面是否清空是三种不同状态。
    private(set) var isPlaying = false
    /// 当前要绘制的整数帧号，由累计时间计算，不按屏幕刷新次数累加。
    private(set) var currentFrame = 0
    /// 每次 play 都先注销旧 link，stop / 离开窗口时也会清理。
    private var displayLink: CADisplayLink?
    /// 单次播放的单调时钟起点；play 是从头重播，不是从暂停位置继续。
    private var startTimestamp: CFTimeInterval = 0
    /// 清屏不删除 movie，之后仍可直接调用 play 重新播放同一资源。
    private(set) var isCleared = false

    public override init(frame: CGRect) {
        super.init(frame: frame)
        // 透明且非 opaque 才能在清屏后露出下面的内容；尺寸变化由 draw 重新计算等比布局。
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    /// 离开窗口时立即释放 display link；弱 target 还覆盖从未进入窗口就被释放的情况。
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else { return }
        displayLink?.invalidate()
        displayLink = nil
        isPlaying = false
    }

    /// 没有外部明确尺寸时提供原动画画布尺寸；实际绘制仍按 bounds 等比居中。
    public override var intrinsicContentSize: CGSize {
        guard let movie else { return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }
        return CGSize(width: movie.params.viewBoxWidth, height: movie.params.viewBoxHeight)
    }

    // MARK: 控制

    /// 从第一帧开始播放。先停止旧 display link，保证每个播放器只有一个帧驱动器。
    /// 无效帧参数会立即完成，避免礼物队列一直等待一个不会播放的动画。
    public func play() {
        guard let movie else { stop(); return }
        guard movie.params.frames > 0, movie.params.frames <= Int32.max,
              movie.params.fps <= Int32.max else { stop(); onComplete?(); return }
        isCleared = false
        isPlaying = true
        currentFrame = 0
        startTimestamp = CACurrentMediaTime()
        displayLink?.invalidate()
        let link = CADisplayLink(target: LspAgSVGADisplayTarget(player: self), selector: #selector(LspAgSVGADisplayTarget.tick(_:)))
        // 使用 common mode，使滚动等主线程交互模式下仍能驱动动画。
        link.add(to: .main, forMode: .common)
        displayLink = link
        setNeedsDisplay()
    }

    /// 只停止播放和按配置清屏，不主动调用 onComplete；页面移除和切换资源也会调用。
    public func stop() {
        isPlaying = false
        displayLink?.invalidate()
        displayLink = nil
        if clearsAfterStop {
            currentFrame = 0
            isCleared = true
            setNeedsDisplay()
        }
    }

    /// display link 只提供刷新时机，时间轴与绘制选择集中在 advance 中，便于确定性测试。
    fileprivate func tick() {
        advance(elapsed: CACurrentMediaTime() - startTimestamp)
    }

    /// 按播放起点至今的累计时间计算帧号，而不是每次 tick 固定前进一帧。
    /// 循环时对总帧数取余，保留掉帧跨越周期后的进度；非循环播放先停止再回调，
    /// 后续 tick 因 `isPlaying` 已关闭而不会重复通知完成。
    func advance(elapsed: TimeInterval) {
        guard isPlaying else { return }
        guard let movie, movie.params.frames > 0 else { stop(); return }
        let progress = max(0, elapsed) * Double(movie.params.effectiveFPS)
        guard progress.isFinite else { stop(); onComplete?(); return }
        if !loop, progress >= Double(movie.params.frames) {
            // 先选末帧；stop 会根据 clearsAfterStop 决定清空还是保留这张末帧。
            currentFrame = max(0, movie.params.frames - 1)
            setNeedsDisplay()
            stop()
            onComplete?()
            return
        }
        let frame = loop ? Int(progress.truncatingRemainder(dividingBy: Double(movie.params.frames))) : Int(progress)
        // 动画 fps 可能低于屏幕刷新率，未换帧时不重复提交绘制请求。
        if frame != currentFrame {
            currentFrame = frame
            setNeedsDisplay()
        }
    }

    // MARK: 绘制

    /// 清屏状态直接跳过绘制，而不是仅把 currentFrame 归零；否则首帧仍会残留。
    public override func draw(_ rect: CGRect) {
        guard !isCleared, let movie, let context = UIGraphicsGetCurrentContext() else { return }
        let viewBox = CGSize(width: movie.params.viewBoxWidth, height: movie.params.viewBoxHeight)
        guard viewBox.width > 0, viewBox.height > 0 else { return }

        // UIImage.draw 依赖 UIKit 当前绘图上下文；显式压栈并配对恢复，避免影响外部绘制。
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        context.saveGState()
        context.clip(to: bounds)
        // 等比居中；通话礼物使用 cover，其他场景保持原来的 contain。
        let widthScale = bounds.width / viewBox.width
        let heightScale = bounds.height / viewBox.height
        let scale = fillsBounds ? max(widthScale, heightScale) : min(widthScale, heightScale)
        context.translateBy(
            x: (bounds.width - viewBox.width * scale) / 2,
            y: (bounds.height - viewBox.height * scale) / 2
        )
        context.scaleBy(x: scale, y: scale)

        // 逐个 sprite 按文件顺序叠加。每个 sprite 保存状态，裁剪和变换不会泄漏到下一个图层。
        for sprite in movie.sprites where !sprite.imageKey.isEmpty {
            guard let frame = sprite.frame(at: currentFrame) else { continue }
            context.saveGState()
            if let transform = frame.transform, !transform.isIdentity {
                context.concatenate(transform.affine)
            }
            if !frame.clipPath.isEmpty {
                // 裁剪路径处于帧的局部坐标系，且同时作用于后面的位图与形状。
                context.addPath(LspAgSVGAPath.path(frame.clipPath).cgPath)
                context.clip()
            }

            let frameRect = CGRect(x: 0, y: 0, width: frame.layout.width, height: frame.layout.height)
            // 找不到位图时仍绘制 shapes，以支持有 key 但没有位图资源的矢量图层。
            if let image = movie.images[sprite.imageKey] {
                image.draw(in: frameRect, blendMode: .normal, alpha: CGFloat(frame.alpha))
            }
            for shape in frame.shapes {
                draw(shape, frameAlpha: frame.alpha, in: context)
            }
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// 先建立局部几何，再叠加 shape transform；填充与描边共用路径，但分开提交 CGContext。
    private func draw(_ shape: LspAgSVGAShape, frameAlpha: Double, in context: CGContext) {
        let path: UIBezierPath
        switch shape.kind {
        case .path(let d):
            path = LspAgSVGAPath.path(d)
        case .rect(let x, let y, let width, let height, let cornerRadius):
            path = UIBezierPath(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerRadius: cornerRadius)
        case .ellipse(let cx, let cy, let rx, let ry):
            path = UIBezierPath(ovalIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        case .keep, .empty:
            // 正常 KEEP 已在解析后展开；无历史形状可继承的 KEEP 不产生图形。
            return
        }
        guard !path.isEmpty else { return }

        context.saveGState()
        if let transform = shape.transform, !transform.isIdentity {
            context.concatenate(transform.affine)
        }
        if let fill = shape.style.fill {
            context.setFillColor(fill.uiColor(frameAlpha: frameAlpha).cgColor)
            context.addPath(path.cgPath)
            context.fillPath()
        }
        if shape.style.strokeWidth > 0 {
            // 未显式提供描边颜色时沿用当前实现的黑色不透明默认值，再乘 frameAlpha。
            let stroke = shape.style.stroke ?? LspAgSVGAColor(r: 0, g: 0, b: 0, a: 1)
            context.setStrokeColor(stroke.uiColor(frameAlpha: frameAlpha).cgColor)
            context.setLineWidth(shape.style.strokeWidth)
            if shape.style.miterLimit > 0 { context.setMiterLimit(shape.style.miterLimit) }
            if shape.style.lineDash.count >= 2 {
                context.setLineDash(phase: 0, lengths: shape.style.lineDash.map { CGFloat($0) })
            }
            // fillPath 会消费当前路径，因此描边前必须再次 addPath。
            context.addPath(path.cgPath)
            context.strokePath()
        }
        context.restoreGState()
    }
}


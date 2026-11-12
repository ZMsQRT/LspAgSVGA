import XCTest
import UIKit
import Compression
import zlib
@testable import LspAgSVGA

@MainActor
final class LspAgSVGATests: XCTestCase {
    func testStandardZlibMovieAndLegacyRawDeflateBothDecode() throws {
        let payload = movieData()
        for encoded in [try compressed(payload), try rawCompressed(payload)] {
            let movie = try LspAgSVGAParser.decode(encoded)
            XCTAssertEqual(movie.params.frames, 4)
            XCTAssertEqual(movie.params.viewBoxWidth, 100)
        }
    }

    func testInflateDoesNotReturnOnlyTheFirstOutputBuffer() throws {
        let original = Data(repeating: 65, count: 300_000)
        XCTAssertEqual(try LspAgSVGAParser.inflate(compressed(original)), original)
        XCTAssertEqual(try LspAgSVGAParser.inflate(rawCompressed(original)), original)
    }

    func testTruncatedStreamsAndWrongChecksumAreRejected() throws {
        let original = Data(repeating: 66, count: 150_000)
        let wrapped = try compressed(original)
        var badChecksum = wrapped
        badChecksum[badChecksum.count - 1] ^= 1
        XCTAssertThrowsError(try LspAgSVGAParser.inflate(badChecksum))
        XCTAssertThrowsError(try LspAgSVGAParser.inflate(Data(wrapped.dropLast(2))))
        XCTAssertThrowsError(try LspAgSVGAParser.inflate(Data(rawCompressed(original).dropLast())))
    }

    func testEmptyLengthDelimitedValueDoesNotConsumeTheNextField() {
        var reader = LspAgProtoReader(Data([0x0A, 0, 0x10, 7]))
        XCTAssertEqual(reader.nextTag()?.field, 1)
        XCTAssertEqual(reader.readString(), "")
        XCTAssertEqual(reader.nextTag()?.field, 2)
        XCTAssertEqual(reader.readVarint(), 7)
        XCTAssertFalse(reader.isInvalid)
    }

    func testMalformedVarintsAndHugeLengthsFailWithoutIntegerTrap() {
        for bytes in [[UInt8](repeating: 0xFF, count: 10), [0x80], [0xFF, 0xFF]] {
            var reader = LspAgProtoReader(Data(bytes))
            _ = reader.readVarint()
            XCTAssertTrue(reader.isInvalid)
        }
        var reader = LspAgProtoReader(Data(varint(UInt64.max)))
        XCTAssertTrue(reader.readBytes().isEmpty)
        XCTAssertTrue(reader.isInvalid)
    }

    func testNestedMalformedMessageAndNonfiniteDimensionsAreRejected() throws {
        let malformed = field(2, [0x0A, 0xFF])
        XCTAssertThrowsError(try LspAgSVGAParser.decode(compressed(Data(malformed))))
        let params = float(1, .nan) + float(2, 100) + integer(4, 4)
        XCTAssertThrowsError(try LspAgSVGAParser.decode(compressed(Data(field(2, params)))))
        let excessiveFrames = float(1, 100) + float(2, 100) + integer(4, UInt64.max)
        XCTAssertThrowsError(try LspAgSVGAParser.decode(compressed(Data(field(2, excessiveFrames)))))
    }

    func testUnplayableMovieParametersAreRejected() throws {
        for params in [float(1, 100) + float(2, 100), integer(4, 4)] {
            XCTAssertThrowsError(try LspAgSVGAParser.decode(compressed(Data(field(2, params)))))
        }
    }

    func testClosedPathIncludesClosureAndRelativeMoveStartsAtSubpathOrigin() {
        let path = LspAgSVGAPath.path("M10 10 L20 10 L20 20 Z m5 0 l0 5")
        var types: [CGPathElementType] = []
        path.cgPath.applyWithBlock { types.append($0.pointee.type) }
        XCTAssertTrue(types.contains(.closeSubpath))
        XCTAssertEqual(path.currentPoint, CGPoint(x: 15, y: 15))
    }

    func testRepeatedCoordinatesAndImplicitLinesAreRendered() {
        let path = LspAgSVGAPath.path("M0 0 10 0 10 20 L0 20 0 0 Z")
        XCTAssertEqual(path.bounds, CGRect(x: 0, y: 0, width: 10, height: 20))
        var lineCount = 0
        path.cgPath.applyWithBlock { if $0.pointee.type == .addLineToPoint { lineCount += 1 } }
        XCTAssertEqual(lineCount, 4)
    }

    func testPathScientificNotationAndAdjacentSignedNumbers() {
        let path = LspAgSVGAPath.path("M1e1-2E1 L+30 +4e1 L.5.5")
        XCTAssertEqual(path.bounds.minY, -20, accuracy: 0.001)
        XCTAssertEqual(path.bounds.maxX, 30, accuracy: 0.001)
        XCTAssertEqual(path.currentPoint, CGPoint(x: 0.5, y: 0.5))
    }

    func testSmoothCurveAfterHorizontalLineDoesNotReflectOldControl() {
        let path = LspAgSVGAPath.path("M0 0 C1 1 2 2 3 3 H10 S20 20 30 30")
        var firstControl = CGPoint.zero
        path.cgPath.applyWithBlock {
            if $0.pointee.type == .addCurveToPoint { firstControl = $0.pointee.points[0] }
        }
        XCTAssertEqual(firstControl, CGPoint(x: 10, y: 3))
    }

    func testPathCacheDoesNotExposeMutableSharedPath() {
        let data = "M0 0 L11 0 L11 19 Z"
        let first = LspAgSVGAPath.path(data)
        first.removeAllPoints()
        XCTAssertEqual(LspAgSVGAPath.path(data).bounds, CGRect(x: 0, y: 0, width: 11, height: 19))
    }

    private func movieData() -> Data {
        Data(field(2, float(1, 100) + float(2, 100) + integer(3, 10) + integer(4, 4)))
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            let byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            bytes.append(byte | (remaining == 0 ? 0 : 0x80))
        } while remaining != 0
        return bytes
    }
    private func field(_ key: UInt64, _ payload: [UInt8]) -> [UInt8] { varint(key << 3 | 2) + varint(UInt64(payload.count)) + payload }
    private func integer(_ key: UInt64, _ value: UInt64) -> [UInt8] { varint(key << 3) + varint(value) }
    private func float(_ key: UInt64, _ value: Float) -> [UInt8] {
        varint(key << 3 | 5) + (0..<4).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) }
    }
    private func compressed(_ data: Data) throws -> Data {
        var count = compressBound(uLong(data.count))
        var output = Data(count: Int(count))
        let status = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compress2(destination.bindMemory(to: UInt8.self).baseAddress!, &count,
                          source.bindMemory(to: UInt8.self).baseAddress!, uLong(data.count), Z_DEFAULT_COMPRESSION)
            }
        }
        XCTAssertEqual(status, Z_OK)
        return output.prefix(Int(count))
    }
    private func rawCompressed(_ data: Data) throws -> Data {
        var output = Data(count: data.count * 2 + 1024)
        let count = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        XCTAssertGreaterThan(count, 0)
        return output.prefix(count)
    }

}

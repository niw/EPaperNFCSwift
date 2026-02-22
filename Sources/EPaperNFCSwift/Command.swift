//
//  Command.swift
//  EPaperNFCSwift
//
//  Created by Yoshimasa Niwa on 2/16/26.
//

import Accelerate
import CoreNFC
import Foundation

struct AuthAPDUCommand: ISO7816APDUCommand {
    typealias Response = EmptyISO7816APDUResponse

    let data = Data([0x00, 0x20, 0x00, 0x01, 0x04, 0x20, 0x09, 0x12, 0x10])
}

private extension DisplayType.ColorPalette {
    init(tlvValue: UInt8) throws {
        switch tlvValue {
        case 0x01, 0x47:
            self = .blackAndWhite
        case 0x07:
            self = .blackWhiteYellowRed
        default:
            throw ISO7816APDUCommandError.unknownResponsePayload
        }
    }

    var bitsPerPixel: Int {
        switch self {
        case .blackAndWhite:
            1
        case .blackWhiteYellowRed:
            2
        }
    }
}

private extension DisplayType.Orientation {
    init(tlvValue: UInt8) throws {
        switch tlvValue {
        case 0x00:
            self = .rotated
        case 0x01:
            self = .normal
        default:
            throw ISO7816APDUCommandError.unknownResponsePayload
        }
    }
}

extension DeviceInfo: ISO7816APDUResponse {
    init(response: NFCISO7816ResponseAPDU) throws {
        guard let payload = response.payload else {
            throw ISO7816APDUCommandError.invalidResponsePayload
        }

        let tlv = payload.asTLV()

        guard let data = tlv[0xC1], data.count == 4 else {
            throw ISO7816APDUCommandError.invalidResponsePayload
        }

        self.id = data.bytes.unsafeLoad(as: UInt32.self).bigEndian

        guard let data = tlv[0xC0], data.count == 10 else {
            throw ISO7816APDUCommandError.invalidResponsePayload
        }

        guard let name = String(data: data, encoding: .ascii) else {
            throw ISO7816APDUCommandError.invalidResponsePayload
        }

        self.name = name

        guard let data = tlv[0xA0], data.count == 7 else {
            throw ISO7816APDUCommandError.invalidResponsePayload
        }

        let colorPaletteValue = data[1]
        let colorPalette = try DisplayType.ColorPalette(tlvValue: colorPaletteValue)

        let pixelWidth = (Int(data[5]) << 8) | Int(data[6])

        let height = (Int(data[3]) << 8) | Int(data[4])
        let pixelHeight = height / colorPalette.bitsPerPixel

        guard let data = tlv[0xA1], data.count == 7 else {
            throw ISO7816APDUCommandError.invalidResponsePayload
        }

        // TODO: This might be wrong, assumed this is `scanType`.
        // TODO: It's unknown how 4.2-inch 2-Color devices report orientation.
        // The protocol suggests it should be `.flipped`, but no TLV value maps to it yet.
        let orientationValue = data[0]
        let orientation = try DisplayType.Orientation(tlvValue: orientationValue)

        displayType = DisplayType(
            colorPalette: colorPalette,
            orientation: orientation,
            width: pixelWidth,
            height: pixelHeight
        )
    }
}

struct DeviceInfoAPDUCommand: ISO7816APDUCommand {
    typealias Response = DeviceInfo

    let data = Data([0x00, 0xD1, 0x00, 0x00, 0x00])
}

private extension Data {
    func chunked(into size: Int) -> [Data] {
        stride(from: 0, to: count, by: size).map { start in
            let end = Swift.min(start + size, count)
            return self[start..<end]
        }
    }

    func rotatedImageData(width: Int, height: Int) -> Data {
        var source = Data(self)
        var result = Data(count: width * height)
        source.withUnsafeMutableBytes { sourcePointer in
            result.withUnsafeMutableBytes { resultPointer in
                var sourceBuffer = vImage_Buffer(
                    data: sourcePointer.baseAddress!,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                var resultBuffer = vImage_Buffer(
                    data: resultPointer.baseAddress!,
                    height: vImagePixelCount(width),
                    width: vImagePixelCount(height),
                    rowBytes: height
                )
                vImageRotate90_Planar8(&sourceBuffer, &resultBuffer, UInt8(kRotate90DegreesClockwise), 0x00, vImage_Flags(kvImageNoFlags))
            }
        }
        return result
    }

    func flippedImageData(width: Int, height: Int) -> Data {
        // Horizontally flip data.
        var source = Data(self)
        var result = Data(count: width * height)
        source.withUnsafeMutableBytes { sourcePointer in
            result.withUnsafeMutableBytes { resultPointer in
                var sourceBuffer = vImage_Buffer(
                    data: sourcePointer.baseAddress!,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                var resultBuffer = vImage_Buffer(
                    data: resultPointer.baseAddress!,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                vImageHorizontalReflect_Planar8(&sourceBuffer, &resultBuffer, vImage_Flags(kvImageNoFlags))
            }
        }
        return result
    }
}

private extension Image {
    var bufferData: Data {
        switch displayType.orientation {
        case .normal:
            data
        case .rotated:
            data.rotatedImageData(width: displayType.width, height: displayType.height)
        case .flipped:
            data.flippedImageData(width: displayType.width, height: displayType.height)
        }
    }

    var bufferWidth: Int {
        switch displayType.orientation {
        case .normal, .flipped:
            displayType.width
        case .rotated:
            displayType.height
        }
    }

    var bufferHeight: Int {
        switch displayType.orientation {
        case .normal, .flipped:
            displayType.height
        case .rotated:
            displayType.width
        }
    }

    var packedData: Data {
        let data = bufferData
        let bitsPerPixel = displayType.colorPalette.bitsPerPixel
        let pixelsPerByte = 8 / bitsPerPixel
        let bytesPerLine = bufferWidth / pixelsPerByte

        var packedData = Data()
        packedData.reserveCapacity(bytesPerLine * bufferHeight)

        for y in 0..<bufferHeight {
            let rowBase = y * bufferWidth
            for storedByteIndex in 0..<bytesPerLine {
                let x0 = (bytesPerLine - 1 - storedByteIndex) * pixelsPerByte
                var byte: UInt8 = 0
                for p in 0..<pixelsPerByte {
                    byte |= data[rowBase + x0 + p] << (p * bitsPerPixel)
                }
                packedData.append(byte)
            }
        }

        return packedData
    }
}

struct SendImageAPDUCommand: ISO7816APDUCommand {
    typealias Response = EmptyISO7816APDUResponse

    var data: Data

    init(
        blockNumber: UInt8,
        fragmentNumber: UInt8,
        fragmentData: Data,
        isLastFragment: Bool
    ) {
        var payload = Data()
        payload.append(blockNumber)
        payload.append(fragmentNumber)
        payload.append(contentsOf: fragmentData)

        let p2: UInt8 = isLastFragment ? 0x01 : 0x00
        var data = Data([0xF0, 0xD3, 0x00, p2, UInt8(payload.count)])
        data.append(contentsOf: payload)

        self.data = data
    }

    static func sendImageAPDUCommands(for image: Image) -> [SendImageAPDUCommand] {
        var commands: [SendImageAPDUCommand] = []

        let packedData = image.packedData
        let blocks = packedData.chunked(into: 2000)

        for (blockIndex, block) in blocks.enumerated() {
            let compressedBlock = compress(block)
            let fragments = compressedBlock.chunked(into: 250)

            for (fragmentIndex, fragment) in fragments.enumerated() {
                let isLastFragment = fragmentIndex == fragments.count - 1

                let command = SendImageAPDUCommand(
                    blockNumber: UInt8(blockIndex),
                    fragmentNumber: UInt8(fragmentIndex),
                    fragmentData: fragment,
                    isLastFragment: isLastFragment
                )
                commands.append(command)
            }
        }

        return commands
    }
}

struct RefreshAPDUCommand: ISO7816APDUCommand {
    typealias Response = EmptyISO7816APDUResponse

    var data: Data

    init(waitForRefresh: Bool = false) {
        let p2: UInt8 = waitForRefresh ? 0x00 : 0x80
        data = Data([0xF0, 0xD4, 0x85, p2, 0x00])
    }
}

struct WaitForRefreshAPDUCommand: ISO7816APDUCommand {
    enum Response: ISO7816APDUResponse {
        case inProgress
        case completed

        init(response: NFCISO7816ResponseAPDU) throws {
            switch response.payload {
            case Data([0x00]):
                self = .completed
            case Data([0x01]):
                self = .inProgress
            default:
                throw ISO7816APDUCommandError.invalidResponsePayload
            }
        }
    }

    let data = Data([0xF0, 0xDE, 0x00, 0x00, 0x01])
}

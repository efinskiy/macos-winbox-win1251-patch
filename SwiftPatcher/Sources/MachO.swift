import Foundation

struct BinaryImage {
    var data: Data

    func integer(_ offset: Int, _ width: Int, bigEndian: Bool = false) throws -> UInt64 {
        guard offset >= 0, (1...8).contains(width), offset <= data.count,
              width <= data.count - offset else {
            throw PatchError.invalid("Исполняемый файл повреждён: выход за границы данных.")
        }
        var value: UInt64 = 0
        for i in 0..<width {
            let shift = (bigEndian ? width - 1 - i : i) * 8
            value |= UInt64(data[offset+i]) << shift
        }
        return value
    }

    mutating func write(_ value: UInt64, at offset: Int, width: Int) throws {
        _ = try integer(offset, width)
        for i in 0..<width { data[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
    }

    mutating func replace(at offset: Int, with bytes: Data) throws {
        guard offset >= 0, offset <= data.count, bytes.count <= data.count-offset else {
            throw PatchError.invalid("Патч выходит за границы исполняемого файла.")
        }
        data.replaceSubrange(offset..<offset+bytes.count, with: bytes)
    }
}

struct FatSlice {
    let cpu: UInt32
    let offset: Int
    let size: Int

    static func read(_ data: Data) throws -> [FatSlice] {
        let image = BinaryImage(data: data)
        guard try image.integer(0, 4, bigEndian: true) == 0xcafebabe else {
            throw PatchError.invalid("Ожидался универсальный исполняемый файл WinBox.")
        }
        let count = Int(try image.integer(4, 4, bigEndian: true))
        guard (1...8).contains(count) else { throw PatchError.invalid("Неверное число архитектур.") }
        var result: [FatSlice] = []
        for i in 0..<count {
            let pos = 8 + 20*i
            let cpu = UInt32(try image.integer(pos, 4, bigEndian: true))
            let offset = Int(try image.integer(pos+8, 4, bigEndian: true))
            let size = Int(try image.integer(pos+12, 4, bigEndian: true))
            let alignment = Int(try image.integer(pos+16, 4, bigEndian: true))
            guard alignment <= 30, offset >= 8 + 20*count, offset <= data.count,
                  size <= data.count-offset, offset % (1 << alignment) == 0,
                  !result.contains(where: { offset < $0.offset+$0.size && $0.offset < offset+size }) else {
                throw PatchError.invalid("Повреждены границы архитектур WinBox.")
            }
            result.append(FatSlice(cpu: cpu, offset: offset, size: size))
        }
        return result
    }
}

struct MachOImage {
    struct Segment {
        let name: String
        let address: UInt64
        let fileOffset: Int
        let fileSize: Int
        let protection: UInt32
    }
    struct Section {
        let address: UInt64
        let size: UInt64
        let fileOffset: Int
    }

    var image: BinaryImage
    let commandCount: Int
    let commandSize: Int
    let segments: [Segment]
    let sections: [Section]

    init(_ data: Data) throws {
        let source = BinaryImage(data: data)
        guard try source.integer(0, 4) == 0xfeedfacf else {
            throw PatchError.invalid("Неверный формат Mach-O.")
        }
        let count = Int(try source.integer(16, 4))
        let size = Int(try source.integer(20, 4))
        guard count <= 4096, data.count >= 32, size <= data.count-32 else {
            throw PatchError.invalid("Повреждены команды загрузки WinBox.")
        }
        var foundSegments: [Segment] = []
        var foundSections: [Section] = []
        var pos = 32
        for _ in 0..<count {
            let command = try source.integer(pos, 4)
            let length = Int(try source.integer(pos+4, 4))
            guard length >= 8, length % 8 == 0, pos <= 32+size,
                  length <= 32+size-pos else { throw PatchError.invalid("Повреждена команда загрузки.") }
            if command == 0x19 {
                guard length >= 72 else { throw PatchError.invalid("Повреждён сегмент Mach-O.") }
                let nameData = data[(pos+8)..<(pos+24)].prefix(while: { $0 != 0 })
                let name = String(bytes: nameData, encoding: .ascii) ?? ""
                let offset64 = try source.integer(pos+40, 8)
                let fileSize64 = try source.integer(pos+48, 8)
                let sectionCount = Int(try source.integer(pos+64, 4))
                guard offset64 <= UInt64(data.count), fileSize64 <= UInt64(data.count)-offset64,
                      sectionCount <= 256, 72 + 80*sectionCount <= length else {
                    throw PatchError.invalid("Сегмент Mach-O выходит за границы файла.")
                }
                foundSegments.append(Segment(name: name, address: try source.integer(pos+24, 8),
                    fileOffset: Int(offset64), fileSize: Int(fileSize64),
                    protection: UInt32(try source.integer(pos+60, 4))))
                for j in 0..<sectionCount {
                    let s = pos + 72 + 80*j
                    let start = try source.integer(s+32, 8), size = try source.integer(s+40, 8)
                    guard size <= UInt64.max-start else { throw PatchError.invalid("Повреждена секция Mach-O.") }
                    foundSections.append(Section(address: start, size: size,
                        fileOffset: Int(try source.integer(s+48, 4))))
                }
            }
            pos += length
        }
        guard pos == 32+size else { throw PatchError.invalid("Неверный размер команд загрузки.") }
        image = source
        commandCount = count
        commandSize = size
        segments = foundSegments
        sections = foundSections
    }

    func fileOffset(_ address: UInt64, length: Int) throws -> Int {
        guard length >= 0 else { throw PatchError.invalid("Неверная длина патча.") }
        for segment in segments where address >= segment.address {
            let delta = address - segment.address
            if delta <= UInt64(segment.fileSize), UInt64(length) <= UInt64(segment.fileSize)-delta {
                return segment.fileOffset + Int(delta)
            }
        }
        throw PatchError.invalid("Адрес патча не соответствует данным WinBox.")
    }

    mutating func addLibrary(_ name: String) throws {
        let encoded = Data(name.utf8) + Data([0])
        let length = (24 + encoded.count + 7) & ~7
        let pos = 32 + commandSize
        guard let firstSection = sections.map(\.fileOffset).filter({ $0 > 0 }).min(),
              pos <= firstSection, length <= firstSection-pos,
              pos <= image.data.count, length <= image.data.count-pos,
              image.data[pos..<pos+length].allSatisfy({ $0 == 0 }) else {
            throw PatchError.invalid("Нет свободного места для подключения декодера.")
        }
        var command = BinaryImage(data: Data(repeating: 0, count: length))
        let fields: [UInt64] = [0x0c, UInt64(length), 24, 0, 0x10000, 0x10000]
        for (i, value) in fields.enumerated() {
            try command.write(value, at: i*4, width: 4)
        }
        try command.replace(at: 24, with: encoded)
        try image.replace(at: pos, with: command.data)
        try image.write(UInt64(commandCount+1), at: 16, width: 4)
        try image.write(UInt64(commandSize+length), at: 20, width: 4)
    }
}

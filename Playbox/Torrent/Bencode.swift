import Foundation

enum BencodeValue: Sendable {
    case integer(Int64)
    case bytes(Data)
    case list([BencodeValue])
    case dictionary([String: BencodeValue])
}

enum BencodeError: Error { case malformed, invalidKey }

struct BencodeDecoder {
    func decode(_ data: Data) throws -> BencodeValue {
        var i = data.startIndex
        let value = try parse(data, &i)
        guard i == data.endIndex else { throw BencodeError.malformed }
        return value
    }

    private func parse(_ data: Data, _ i: inout Data.Index) throws -> BencodeValue {
        guard i < data.endIndex else { throw BencodeError.malformed }
        switch data[i] {
        case 105:
            i += 1; let start = i
            while i < data.endIndex, data[i] != 101 { i += 1 }
            guard i < data.endIndex, let n = Int64(String(decoding: data[start..<i], as: UTF8.self)) else { throw BencodeError.malformed }
            i += 1; return .integer(n)
        case 108:
            i += 1; var out:[BencodeValue] = []
            while i < data.endIndex, data[i] != 101 { out.append(try parse(data, &i)) }
            guard i < data.endIndex else { throw BencodeError.malformed }; i += 1; return .list(out)
        case 100:
            i += 1; var out:[String:BencodeValue] = [:]
            while i < data.endIndex, data[i] != 101 {
                guard case .bytes(let k) = try parse(data, &i), let key = String(data:k, encoding:.utf8) else { throw BencodeError.invalidKey }
                out[key] = try parse(data, &i)
            }
            guard i < data.endIndex else { throw BencodeError.malformed }; i += 1; return .dictionary(out)
        case 48...57:
            let start = i
            while i < data.endIndex, data[i] != 58 { i += 1 }
            guard i < data.endIndex, let length = Int(String(decoding:data[start..<i], as:UTF8.self)) else { throw BencodeError.malformed }
            i += 1; guard length >= 0, i + length <= data.endIndex else { throw BencodeError.malformed }
            let bytes = Data(data[i..<(i+length)]); i += length; return .bytes(bytes)
        default: throw BencodeError.malformed
        }
    }
}

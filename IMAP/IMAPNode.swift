//import Foundation
//
//// MARK: - AST (Abstract Syntax Tree)
//
///// A single parsed IMAP value
//public enum IMAPValue: Equatable, CustomStringConvertible {
//    case atom(String)
//    case number(Int)
//    case quoted(String)
//    case literal(Data)
//    case nilValue
//    case list([IMAPValue])
//
//    public var description: String {
//        switch self {
//        case .atom(let s): return "Atom(\(s))"
//        case .number(let n): return "Number(\(n))"
//        case .quoted(let s): return "Quoted(\"\(s)\")"
//        case .literal(let d): return "Literal(\(d.count) bytes)"
//        case .nilValue: return "NIL"
//        case .list(let arr): return "List(\(arr))"
//        }
//    }
//}
//
///// Top-level response line
//public enum IMAPResponse: CustomStringConvertible {
//    case untagged(type: String, data: [IMAPValue])
//    case tagged(tag: String, type: String, data: [IMAPValue])
//    case continuation(text: String)
//
//    public var description: String {
//        switch self {
//        case .untagged(let type, let data):
//            return "* \(type) \(data)"
//        case .tagged(let tag, let type, let data):
//            return "\(tag) \(type) \(data)"
//        case .continuation(let text):
//            return "+ \(text)"
//        }
//    }
//}
//
//// MARK: - Errors
//
//public enum IMAPParseError: Error, CustomStringConvertible {
//    case unexpectedEnd
//    case invalidToken(String)
//    case invalidNumber(String)
//    case invalidLiteral
//    case expectedCRLF
//    case utf8Error
//
//    public var description: String {
//        switch self {
//        case .unexpectedEnd: return "Unexpected end of input"
//        case .invalidToken(let t): return "Invalid token: \(t)"
//        case .invalidNumber(let s): return "Invalid number: \(s)"
//        case .invalidLiteral: return "Invalid literal block"
//        case .expectedCRLF: return "Expected CRLF sequence"
//        case .utf8Error: return "Invalid UTF-8 data"
//        }
//    }
//}
//
//// MARK: - Lexer (low-level tokenizer)
//
//final class IMAPLexer {
//    let data: Data        // <-- not private, so parser can read it
//    var index: Int = 0
//
//    init(_ data: Data) { self.data = data }
//
//    var remaining: Int { data.count - index }
//    var atEnd: Bool { index >= data.count }
//
//    func peek() throws -> UInt8 {
//        guard !atEnd else { throw IMAPParseError.unexpectedEnd }
//        return data[index]
//    }
//
//    func advance() throws -> UInt8 {
//        let b = try peek()
//        index += 1
//        return b
//    }
//
//    func consumeCRLF() throws {
//        guard remaining >= 2 else { throw IMAPParseError.expectedCRLF }
//        guard data[index] == 13, data[index + 1] == 10 else { throw IMAPParseError.expectedCRLF }
//        index += 2
//    }
//
//    func skipSpaces() {
//        while index < data.count, data[index] == 32 { index += 1 }
//    }
//
//    func readUntilCRLF() throws -> Data {
//        let start = index
//        while index + 1 < data.count {
//            if data[index] == 13, data[index + 1] == 10 {
//                return data.subdata(in: start..<index)
//            }
//            index += 1
//        }
//        throw IMAPParseError.expectedCRLF
//    }
//
//    func readToken() throws -> String {
//        let start = index
//        while index < data.count {
//            let b = data[index]
//            if [40,41,123,125,34,32,13,10].contains(b) { break }
//            index += 1
//        }
//        guard index > start else { throw IMAPParseError.invalidToken("") }
//        let slice = data.subdata(in: start..<index)
//        guard let str = String(data: slice, encoding: .utf8) else { throw IMAPParseError.utf8Error }
//        return str
//    }
//}
//
//// MARK: - Parser
//
//public final class IMAPParser {
//    private let lexer: IMAPLexer
//
//    public init(_ input: Data) { self.lexer = IMAPLexer(input) }
//    public convenience init(_ input: String) { self.init(Data(input.utf8)) }
//
//    // Parse one complete response line
//    public func parseResponse() throws -> IMAPResponse {
//        lexer.skipSpaces()
//        let first = try lexer.readToken()
//
//        if first == "*" {
//            lexer.skipSpaces()
//            let type = try lexer.readToken()
//            let values = try parseValues()
//            try lexer.consumeCRLF() // consume final CRLF of response
//            return .untagged(type: type, data: values)
//        } else if first == "+" {
//            let textData = try lexer.readUntilCRLF()
//            try lexer.consumeCRLF()
//            let text = String(data: textData, encoding: .utf8) ?? ""
//            return .continuation(text: text)
//        } else {
//            let tag = first
//            lexer.skipSpaces()
//            let type = try lexer.readToken()
//            let values = try parseValues()
//            try lexer.consumeCRLF()
//            return .tagged(tag: tag, type: type, data: values)
//        }
//    }
//
//    // MARK: - Value parsing
//
//    private func parseValues() throws -> [IMAPValue] {
//        var values: [IMAPValue] = []
//        lexer.skipSpaces()
//        while !lexer.atEnd {
//            values.append(try parseValue())
//            lexer.skipSpaces()
//        }
//        return values
//    }
//
//    private func parseValue() throws -> IMAPValue {
//        lexer.skipSpaces()
//        guard !lexer.atEnd else { throw IMAPParseError.unexpectedEnd }
//        switch try lexer.peek() {
//        case 40: return try parseList()
//        case 34: return try parseQuoted()
//        case 123: return try parseLiteral()
//        default:
//            let token = try lexer.readToken()
//            if token.uppercased() == "NIL" { return .nilValue }
//            if let n = Int(token) { return .number(n) }
//            return .atom(token)
//        }
//    }
//
//    private func parseQuoted() throws -> IMAPValue {
//        _ = try lexer.advance() // consume "
//        var buf = Data()
//        while true {
//            let b = try lexer.advance()
//            if b == 34 { break }
//            if b == 92 { buf.append(try lexer.advance()) }
//            else { buf.append(b) }
//        }
//        guard let s = String(data: buf, encoding: .utf8) else { throw IMAPParseError.utf8Error }
//        return .quoted(s)
//    }
//
//    private func parseLiteral() throws -> IMAPValue {
//        _ = try lexer.advance() // consume "{"
//        var digits = ""
//        while true {
//            let b = try lexer.advance()
//            if b == 125 { break } // "}"
//            guard let scalar = UnicodeScalar(Int(b)) else { throw IMAPParseError.invalidLiteral }
//            digits.append(Character(scalar))
//        }
//        guard let size = Int(digits.trimmingCharacters(in: .whitespaces)) else {
//            throw IMAPParseError.invalidNumber(digits)
//        }
//        try lexer.consumeCRLF() // the {N}\r\n terminator
//        guard lexer.remaining >= size else { throw IMAPParseError.unexpectedEnd }
//
//        let start = lexer.index
//        lexer.index += size
//        let block = lexer.data.subdata(in: start..<start+size)
//
//        // 🚫 DO NOT consume the trailing CRLF here — leave it for the parser
//
//        return .literal(block)
//    }
//
//    private func parseList() throws -> IMAPValue {
//        _ = try lexer.advance() // consume "("
//        var items: [IMAPValue] = []
//        lexer.skipSpaces()
//        while !lexer.atEnd {
//            // Skip CRLFs that separate literal from following tokens
//            if lexer.remaining >= 2,
//               lexer.data[lexer.index] == 13,
//               lexer.data[lexer.index + 1] == 10 {
//                lexer.index += 2
//                lexer.skipSpaces()
//                continue
//            }
//            if try lexer.peek() == 41 { // ")"
//                _ = try lexer.advance()
//                break
//            }
//            items.append(try parseValue())
//            lexer.skipSpaces()
//        }
//        return .list(items)
//    }
//}

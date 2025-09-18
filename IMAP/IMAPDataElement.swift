import Foundation

// ============================
// IMAP AST
// ============================
public enum IMAPValue: CustomStringConvertible {
    case atom(String)
    case number(Int)
    case string(String)    // quoted-string
    case literal(Data)     // literal payload (байтово-точное хранение)
    case nilValue
    case list([IMAPValue])

    public var description: String {
        switch self {
        case .atom(let s): return "atom(\(s))"
        case .number(let n): return "number(\(n))"
        case .string(let s): return "string(\"\(s)\")"
        case .literal(let d):
            if let s = String(data: d, encoding: .utf8) {
                return "literal(\"\(s)\")"
            } else {
                return "literal(<\(d.count) bytes>)"
            }
        case .nilValue: return "NIL"
        case .list(let arr): return "list(\(arr.map { $0.description }.joined(separator: ", ")))"
        }
    }
}

// ============================
// Tokenizer (байтовый)
// ============================
public enum Token: CustomStringConvertible {
    case lparen
    case rparen
    case atom(String)
    case quoted(String)
    case literal(Data) // сразу содержит данные
    case eof

    public var description: String {
        switch self {
        case .lparen: return "("
        case .rparen: return ")"
        case .atom(let s): return "ATOM(\(s))"
        case .quoted(let s): return "QUOTED(\(s))"
        case .literal(let d): return "LITERAL(\(d.count) bytes)"
        case .eof: return "EOF"
        }
    }
}

fileprivate struct Tokenizer {
    private let bytes: [UInt8]
    private var idx: Int = 0
    init(_ input: String) {
        self.bytes = Array(input.utf8)
        self.idx = 0
    }
    private mutating func peekByte() -> UInt8? {
        guard idx < bytes.count else { return nil }
        return bytes[idx]
    }
    
    private mutating func advance(_ n: Int = 1) -> Void {
        idx = Swift.min(bytes.count, idx + n)
    }
    private mutating func consumeWhile(_ cond: (UInt8) -> Bool) -> [UInt8] {
        var out: [UInt8] = []
        while let b = peekByte(), cond(b) {
            out.append(b)
            advance()
        }
        return out
    }
    private mutating func skipWhitespace() {
        _ = consumeWhile { b in
            b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0A
        }
    }

    mutating func nextToken() -> Token {
        skipWhitespace()
        guard let b = peekByte() else { return .eof }

        // '('
        if b == 0x28 { advance(); return .lparen }
        // ')'
        if b == 0x29 { advance(); return .rparen }
        // quoted string: " ... " with backslash escapes
        if b == 0x22 {
            advance() // skip opening "
            var content: [UInt8] = []
            while let ch = peekByte() {
                if ch == 0x22 { advance(); break } // closing "
                if ch == 0x5C { // backslash '\'
                    advance()
                    if let esc = peekByte() {
                        content.append(esc)
                        advance()
                    }
                } else {
                    content.append(ch)
                    advance()
                }
            }
            let s = String(decoding: content, as: UTF8.self)
            return .quoted(s)
        }
        // literal: {N}\r\n then N bytes
        if b == 0x7B { // '{'
            advance() // skip '{'
            let numBytes = consumeWhile { $0 >= 0x30 && $0 <= 0x39 } // digits
            // skip closing '}'
            if peekByte() == 0x7D { advance() }
            // RFC: after "}" there is CRLF. Skip exactly one CRLF if present.
            if peekByte() == 0x0D { advance(); if peekByte() == 0x0A { advance() } }
            else if peekByte() == 0x0A { advance() }
            // parse length
            let len = Int(String(decoding: numBytes, as: UTF8.self)) ?? 0
            // read exactly len bytes (byte-accurate)
            var taken: [UInt8] = []
            for _ in 0..<len {
                if let ch = peekByte() {
                    taken.append(ch)
                    advance()
                } else {
                    break
                }
            }
            // after literal data there may be a CRLF — skip a single CRLF if present
            if peekByte() == 0x0D { advance(); if peekByte() == 0x0A { advance() } }
            else if peekByte() == 0x0A { advance() }
            return .literal(Data(taken))
        }
        // atom (until specials or whitespace)
        let atomBytes = consumeWhile { ch in
            // specials: parentheses, quote, brace, spaces, CRLF, tab
            return !(ch == 0x28 || ch == 0x29 || ch == 0x22 || ch == 0x7B || ch == 0x20 || ch == 0x09 || ch == 0x0D || ch == 0x0A)
        }
        let atomStr = String(decoding: atomBytes, as: UTF8.self)
        return .atom(atomStr)
    }
}

// ============================
// Parser
// ============================
public enum ParserError: Error, CustomStringConvertible {
    case unexpectedToken(Token)
    case unexpectedEOF
    case invalidNumber(String)
    case generic(String)
    public var description: String {
        switch self {
        case .unexpectedToken(let t): return "Unexpected token: \(t)"
        case .unexpectedEOF: return "Unexpected EOF"
        case .invalidNumber(let s): return "Invalid number: \(s)"
        case .generic(let s): return "Parse error: \(s)"
        }
    }
}

public struct IMAPParser {
    private var tokenizer: Tokenizer
    private var lookahead: Token = .eof

    public init(input: String) {
        self.tokenizer = Tokenizer(input)
        self.lookahead = tokenizer.nextToken()
    }
    private mutating func advance() {
        lookahead = tokenizer.nextToken()
    }

    public mutating func parseValue() throws -> IMAPValue {
        switch lookahead {
        case .eof: throw ParserError.unexpectedEOF
        case .lparen:
            return try parseList()
        case .rparen:
            throw ParserError.unexpectedToken(lookahead)
        case .atom(let a):
            advance()
            if a.uppercased() == "NIL" { return .nilValue }
            if let n = Int(a) { return .number(n) }
            return .atom(a)
        case .quoted(let s):
            advance()
            return .string(s)
        case .literal(let d):
            advance()
            return .literal(d)
        }
    }

    private mutating func parseList() throws -> IMAPValue {
        // consume '('
        guard case .lparen = lookahead else { throw ParserError.unexpectedToken(lookahead) }
        advance()
        var items: [IMAPValue] = []
        while true {
            switch lookahead {
            case .rparen:
                advance()
                return .list(items)
            case .eof:
                throw ParserError.unexpectedEOF
            default:
                let v = try parseValue()
                items.append(v)
            }
        }
    }
}

// ============================
// MARK: - Примеры и тесты
// ============================

class Kek {

    static func test() {
        // --- Test 1: простой список и atoms
        do {
            var parser = IMAPParser(input: "(FLAGS (\\Seen \\Answered) UID 4829013)")
            let parsed = try parser.parseValue()
            print("Test1:", parsed) // ожидаем list([...])
            // -> list([atom("FLAGS"), list([atom("\Seen"), atom("\Answered")]), atom("UID"), number(4829013)])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 2: quoted strings и NIL
        do {
            var parser = IMAPParser(input: "(ENVELOPE (\"Mon, 7 May 2024 12:34:56 +0000\" \"Subject here\" (\"From\" NIL \"from@example.com\") NIL NIL) NIL NIL)")
            let v = try parser.parseValue()
            print("Test2:", v)
        } catch {
            assertionFailure(error.localizedDescription)
        }


        // --- Test 3: literal — input содержит marker {11} и literalProvider вернёт 11 байт
        do {
            let input = "(BODY {11}\r\nHello World\r\n)"
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test3:", v)
            // -> list([atom("BODY"), literal("Hello World")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 4: complex IMAP BODYSTRUCTURE-like example (nested lists)
        do {
            let example = """
        ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 1152 23) (\"IMAGE\" \"JPEG\" (\"NAME\" \"pic.jpg\") NIL NIL \"BASE64\" 34567) \"MIXED\")
        """
            var parser = IMAPParser(input: example)
            let v = try parser.parseValue()
            print("Test4:", v)
            // Вы получили структуру вида list([ list([...part1...]), list([...part2...]), atom("MIXED") ])
        } catch {
            assertionFailure(error.localizedDescription)
        }
    }
}

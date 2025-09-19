import Foundation

// ============================
// IMAP AST (Abstract Syntax Tree)
// ============================
// RFC 3501 §4: базовые синтаксические элементы
public enum IMAPValue: CustomStringConvertible {
    case atom(String)     // RFC 3501 §4.1.2 Atom — произвольное слово без пробелов и спецсимволов
    case number(Int)      // RFC 3501 §4.1.3 Number — целое число
    case string(String)   // RFC 3501 §4.3 Quoted string — строка в кавычках
    case literal(Data)    // RFC 3501 §4.3 Literal — строка фиксированной длины {N}\r\n<data>
    case nilValue         // RFC 3501 §4.5 NIL — специальное значение (null)
    case list([IMAPValue])// RFC 3501 §4.4 Parenthesized list — список в скобках

    // Для удобства печати дерева
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
        case .list(let arr):
            return "list(\(arr.map { $0.description }.joined(separator: ", ")))"
        }
    }
}

// ============================
// Tokenizer (лексический анализатор)
// ============================
// Превращает "сырую" строку ответа IMAP в последовательность токенов.
// RFC 3501 §4.1-§4.5 описывают, какие синтаксические элементы поддерживаются.
public enum Token: CustomStringConvertible, Equatable {
    case lparen               // "(" — начало списка
    case rparen               // ")" — конец списка
    case lbracket             // "[" – начало списка
    case rbracket             // "]" – конец списка
    case atom(String)         // Atom — слово (RFC 3501 §4.1.2)
    case quoted(String)       // Quoted string — строка в кавычках (RFC 3501 §4.3)
    case literal(Data)        // Literal — {N}\r\n<data> (RFC 3501 §4.3)
    case eof                  // Конец ввода

    public var description: String {
        switch self {
        case .lparen: return "("
        case .rparen: return ")"
        case .lbracket: return "["
        case .rbracket: return "]"
        case .atom(let s): return "ATOM(\(s))"
        case .quoted(let s): return "QUOTED(\(s))"
        case .literal(let d): return "LITERAL(\(d.count) bytes)"
        case .eof: return "EOF"
        }
    }
}

// ============================
// ASCII константы для читаемости
// ============================
fileprivate enum ASCII {
    static let lparen: UInt8   = 0x28 // (
    static let rparen: UInt8   = 0x29 // )
    static let quote: UInt8    = 0x22 // "
    static let backslash: UInt8 = 0x5C // \
    static let lbrace: UInt8   = 0x7B // {
    static let rbrace: UInt8   = 0x7D // }
    static let lbracket: UInt8 = 0x5B // [
    static let rbracket: UInt8 = 0x5D // ]
    static let space: UInt8    = 0x20 // пробел
    static let tab: UInt8      = 0x09 // \t
    static let cr: UInt8       = 0x0D // \r
    static let lf: UInt8       = 0x0A // \n
    static let zero: UInt8     = 0x30 // '0'
    static let nine: UInt8     = 0x39 // '9'
}

fileprivate struct Tokenizer {
    private let bytes: [UInt8]   // Весь вход IMAP как массив байтов
    private var idx: Int = 0     // Текущая позиция

    init(_ input: String) {
        self.bytes = Array(input.utf8)
        self.idx = 0
    }

    // Смотрим текущий байт, не сдвигая указатель
    private mutating func peekByte() -> UInt8? {
        guard idx < bytes.count else { return nil }
        return bytes[idx]
    }

    // Сдвигаем указатель на n байтов
    private mutating func advance(_ n: Int = 1) {
        idx = Swift.min(bytes.count, idx + n)
    }

    // Читаем подряд байты, пока выполняется условие cond
    private mutating func consumeWhile(_ cond: (UInt8) -> Bool) -> [UInt8] {
        var out: [UInt8] = []
        while let b = peekByte(), cond(b) {
            out.append(b)
            advance()
        }
        return out
    }

    // Пропускаем пробелы, табы и переводы строк (RFC 3501 §9 defines SPACE, CRLF)
    private mutating func skipWhitespace() {
        _ = consumeWhile { b in
            b == ASCII.space || b == ASCII.tab || b == ASCII.cr || b == ASCII.lf
        }
    }

    // Главная функция: возвращает следующий токен
    mutating func nextToken() -> Token {
        skipWhitespace()
        guard let b = peekByte() else { return .eof }

        // "(" → начало списка
        if b == ASCII.lparen { advance(); return .lparen }
        // ")" → конец списка
        if b == ASCII.rparen { advance(); return .rparen }

        // "[" → начало списка
        if b == ASCII.lbracket { advance(); return .lbracket }
        // "]" → конец списка
        if b == ASCII.rbracket { advance(); return .rbracket }

        // Quoted string (RFC 3501 §4.3)
        if b == ASCII.quote { // открывающая кавычка "
            advance() // пропускаем её
            var content: [UInt8] = []
            while let ch = peekByte() {
                if ch == ASCII.quote { // закрывающая кавычка "
                    advance()
                    break
                }
                if ch == ASCII.backslash { // backslash "\" — escape
                    advance()
                    if let esc = peekByte() {
                        // Добавляем символ после '\'
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

        // Literal (RFC 3501 §4.3)
        if b == ASCII.lbrace { // '{'
            advance()
            // читаем число (длину в байтах)
            let numBytes = consumeWhile { $0 >= ASCII.zero && $0 <= ASCII.nine } // ASCII digits
            if peekByte() == ASCII.rbrace { advance() } // закрывающая '}'

            // после } должен идти CRLF
            if peekByte() == ASCII.cr { advance(); if peekByte() == ASCII.lf { advance() } }
            else if peekByte() == ASCII.lf { advance() }

            let len = Int(String(decoding: numBytes, as: UTF8.self)) ?? 0

            // читаем ровно len байт
            var taken: [UInt8] = []
            for _ in 0..<len {
                if let ch = peekByte() {
                    taken.append(ch)
                    advance()
                } else { break }
            }

            // после литерала может быть CRLF → пропускаем
            if peekByte() == ASCII.cr { advance(); if peekByte() == ASCII.lf { advance() } }
            else if peekByte() == ASCII.lf { advance() }

            return .literal(Data(taken))
        }

        // Atom (RFC 3501 §4.1.2)
        // Читаем символы до пробела или спецсимвола
        let atomBytes = consumeWhile { ch in
            !(ch == ASCII.lparen || ch == ASCII.rparen ||
              ch == ASCII.lbracket || ch == ASCII.rbracket ||
              ch == ASCII.quote || ch == ASCII.lbrace ||
              ch == ASCII.space || ch == ASCII.tab ||
              ch == ASCII.cr || ch == ASCII.lf)
        }
        let atomStr = String(decoding: atomBytes, as: UTF8.self)
        return .atom(atomStr)
    }
}

// ============================
// Parser (синтаксический анализатор)
// ============================
// Строит дерево IMAPValue из последовательности токенов.
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
    private var lookahead: Token = .eof // текущий токен

    public init(input: String) {
        self.tokenizer = Tokenizer(input)
        self.lookahead = tokenizer.nextToken()
    }

    private mutating func advance() {
        lookahead = tokenizer.nextToken()
    }

    // Парсинг одного значения IMAP
    public mutating func parseValue() throws -> IMAPValue {
        switch lookahead {
        case .eof: throw ParserError.unexpectedEOF
        case .lparen:
            return try parseList(start: .lparen, end: .rparen)
        case .lbracket:
            return try parseList(start: .lbracket, end: .rbracket)
        case .rparen, .rbracket:
            throw ParserError.unexpectedToken(lookahead)
        case .atom(let a):
            advance()
            // RFC 3501 §4.5 — NIL
            if a.uppercased() == "NIL" { return .nilValue }
            // RFC 3501 §4.1.3 — число
            if let n = Int(a) { return .number(n) }
            // обычный атом
            return .atom(a)

        case .quoted(let s):
            advance()
            return .string(s) // RFC 3501 §4.3

        case .literal(let d):
            advance()
            return .literal(d) // RFC 3501 §4.3
        }
    }

    // Парсинг списка (RFC 3501 §4.4)
    private mutating func parseList(start: Token, end: Token) throws -> IMAPValue {
        guard lookahead == start else {
            throw ParserError.unexpectedToken(lookahead)
        }
        advance() // пропускаем открывающую скобку
        var items: [IMAPValue] = []

        while true {
            if lookahead == end {
                advance()
                return .list(items)
            }
            if lookahead == .eof {
                throw ParserError.unexpectedEOF
            }
            let v = try parseValue()
            items.append(v)
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

        // --- Test 5
        do {
            let input = "(BODY {21}\r\nФывап Апыап\r\n)"
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test5:", v)
            // -> list([atom("BODY"), literal("Hello World")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 6
        do {
            // Валидный IMAP: строка целиком внутри кавычек
            let input = "(BODY \"=?utf-8?Q?App\\\")?=\")"
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test6:", v)
            // -> list([atom("BODY"), string("=?utf-8?Q?App)?=")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 7
        do {
            let input = #"([PERMANENTFLAGS (\Answered \Flagged \Deleted \Seen \Draft \*)])"#
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test7:", v)

            // -> Фактический результат:
            // Test7: list(atom([PERMANENTFLAGS), list(atom(\Answered), atom(\Flagged), atom(\Deleted), atom(\Seen), atom(\Draft), atom(\*)), atom(]))

        } catch {
            assertionFailure(error.localizedDescription)
        }
    }
}

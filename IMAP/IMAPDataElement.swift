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
public enum Token: CustomStringConvertible {
    case lparen               // "(" — начало списка
    case rparen               // ")" — конец списка
    case atom(String)         // Atom — слово (RFC 3501 §4.1.2)
    case quoted(String)       // Quoted string — строка в кавычках (RFC 3501 §4.3)
    case literal(Data)        // Literal — {N}\r\n<data> (RFC 3501 §4.3)
    case eof                  // Конец ввода

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
            b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0A
        }
    }

    // Главная функция: возвращает следующий токен
    mutating func nextToken() -> Token {
        skipWhitespace()
        guard let b = peekByte() else { return .eof }

        // "(" → начало списка
        if b == 0x28 { advance(); return .lparen }
        // ")" → конец списка
        if b == 0x29 { advance(); return .rparen }

        // Quoted string (RFC 3501 §4.3)
        if b == 0x22 { // открывающая кавычка "
            advance() // пропускаем её
            var content: [UInt8] = []
            while let ch = peekByte() {
                if ch == 0x22 { // закрывающая кавычка "
                    advance()
                    break
                }
                if ch == 0x5C { // backslash "\" — escape
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
        if b == 0x7B { // '{'
            advance()
            // читаем число (длину в байтах)
            let numBytes = consumeWhile { $0 >= 0x30 && $0 <= 0x39 } // ASCII digits
            if peekByte() == 0x7D { advance() } // закрывающая '}'

            // после } должен идти CRLF
            if peekByte() == 0x0D { advance(); if peekByte() == 0x0A { advance() } }
            else if peekByte() == 0x0A { advance() }

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
            if peekByte() == 0x0D { advance(); if peekByte() == 0x0A { advance() } }
            else if peekByte() == 0x0A { advance() }

            return .literal(Data(taken))
        }

        // Atom (RFC 3501 §4.1.2)
        // Читаем символы до пробела или спецсимвола
        let atomBytes = consumeWhile { ch in
            !(ch == 0x28 || ch == 0x29 || ch == 0x22 || ch == 0x7B ||
              ch == 0x20 || ch == 0x09 || ch == 0x0D || ch == 0x0A)
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
        case .eof:
            throw ParserError.unexpectedEOF

        case .lparen:
            return try parseList() // RFC 3501 §4.4

        case .rparen:
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
    private mutating func parseList() throws -> IMAPValue {
        guard case .lparen = lookahead else {
            throw ParserError.unexpectedToken(lookahead)
        }
        advance() // пропускаем "("
        var items: [IMAPValue] = []

        while true {
            switch lookahead {
            case .rparen: // конец списка
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
    }
}

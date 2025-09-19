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
class IMAPTestCases {

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
            // -> list([atom("ENVELOPE"), list([string("Mon, 7 May 2024 12:34:56 +0000"), string("Subject here"),
            //      list([string("From"), NIL, string("from@example.com")]), NIL, NIL]), NIL, NIL])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 3: literal
        do {
            let input = "(BODY {11}\r\nHello World\r\n)"
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test3:", v)
            // -> list([atom("BODY"), literal("Hello World")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 4: BODYSTRUCTURE-like
        do {
            let example = """
        ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 1152 23) (\"IMAGE\" \"JPEG\" (\"NAME\" \"pic.jpg\") NIL NIL \"BASE64\" 34567) \"MIXED\")
        """
            var parser = IMAPParser(input: example)
            let v = try parser.parseValue()
            print("Test4:", v)
            // -> list([list([string("TEXT"), string("PLAIN"), list([string("CHARSET"), string("UTF-8")]), NIL, NIL, string("7BIT"), number(1152), number(23)]),
            //           list([string("IMAGE"), string("JPEG"), list([string("NAME"), string("pic.jpg")]), NIL, NIL, string("BASE64"), number(34567)]),
            //           string("MIXED")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 5: literal с UTF-8 (русский текст)
        do {
            let input = "(BODY {21}\r\nФывап Апыап\r\n)"
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test5:", v)
            // -> list([atom("BODY"), literal("Фывап Апыап")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 6: quoted string с экранированной кавычкой
        do {
            let input = "(BODY \"=?utf-8?Q?App\\\")?=\")"
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test6:", v)
            // -> list([atom("BODY"), string("=?utf-8?Q?App)?=")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 7: квадратные скобки (PERMANENTFLAGS)
        do {
            let input = #"([PERMANENTFLAGS (\Answered \Flagged \Deleted \Seen \Draft \*)])"#
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test7:", v)
            // -> list([list([atom("PERMANENTFLAGS"), list([atom("\Answered"), atom("\Flagged"),
            //      atom("\Deleted"), atom("\Seen"), atom("\Draft"), atom("\*")])])])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        chatGptTestsImapStructure()
        chatGptTestsImapLanguages()
    }
}

// MARK: - Chat GPT generated tests

extension IMAPTestCases {

    static func chatGptTestsImapStructure() {

        // --- Test 8: пустой список
        do {
            var parser = IMAPParser(input: "()")
            let v = try parser.parseValue()
            print("Test8:", v)
            // -> list([])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 9: atom "NIL" должен парситься как nilValue
        do {
            var parser = IMAPParser(input: "NIL")
            let v = try parser.parseValue()
            print("Test9:", v)
            // -> NIL
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 10: число без скобок
        do {
            var parser = IMAPParser(input: "12345")
            let v = try parser.parseValue()
            print("Test10:", v)
            // -> number(12345)
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 11: вложенные списки
        do {
            var parser = IMAPParser(input: "(A (B (C D) E) F)")
            let v = try parser.parseValue()
            print("Test11:", v)
            // -> list([atom("A"), list([atom("B"), list([atom("C"), atom("D")]), atom("E")]), atom("F")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 12: пустой литерал {0}
        do {
            let input = "(BODY {0}\r\n\r\n)"
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test12:", v)
            // -> list([atom("BODY"), literal("")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 13: quoted string с escape внутри
        do {
            let input = "(BODY \"Line1\\\"Line2\")"
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test13:", v)
            // -> list([atom("BODY"), string("Line1\"Line2")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 14: square brackets вложенные в список
        do {
            let input = "(OK [READ-WRITE])"
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test14:", v)
            // -> list([atom("OK"), list([atom("READ-WRITE")])])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 9: atom "NIL" должен парситься как nilValue
        do {
            var parser = IMAPParser(input: "NIL")
            let v = try parser.parseValue()
            print("Test9:", v)
            // -> NIL
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 10: число без скобок
        do {
            var parser = IMAPParser(input: "12345")
            let v = try parser.parseValue()
            print("Test10:", v)
            // -> number(12345)
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 11: вложенные списки
        do {
            var parser = IMAPParser(input: "(A (B (C D) E) F)")
            let v = try parser.parseValue()
            print("Test11:", v)
            // -> list([atom("A"), list([atom("B"), list([atom("C"), atom("D")]), atom("E")]), atom("F")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 12: пустой литерал {0}
        do {
            let input = "(BODY {0}\r\n\r\n)"
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test12:", v)
            // -> list([atom("BODY"), literal("")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 13: quoted string с escape внутри
        do {
            let input = "(BODY \"Line1\\\"Line2\")"
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test13:", v)
            // -> list([atom("BODY"), string("Line1\"Line2")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 14: square brackets вложенные в список
        do {
            let input = "(OK [READ-WRITE])"
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test14:", v)
            // -> list([atom("OK"), list([atom("READ-WRITE")])])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 15
        do {
            var parser = IMAPParser(input: "(INBOX)")
            let v = try parser.parseValue()
            print("Test15:", v)
            // -> list([atom("INBOX")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 16
        do {
            var parser = IMAPParser(input: "(UID 12345 FLAGS (\\Seen))")
            let v = try parser.parseValue()
            print("Test16:", v)
            // -> list([atom("UID"), number(12345), atom("FLAGS"), list([atom("\Seen")])])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 17
        do {
            var parser = IMAPParser(input: "(\"simple quoted\")")
            let v = try parser.parseValue()
            print("Test17:", v)
            // -> list([string("simple quoted")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 18
        do {
            var parser = IMAPParser(input: "(HEADER.FIELDS (Subject From))")
            let v = try parser.parseValue()
            print("Test18:", v)
            // -> list([atom("HEADER.FIELDS"), list([atom("Subject"), atom("From")])])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 19
        do {
            var parser = IMAPParser(input: "(X-HEADER \"value with spaces\")")
            let v = try parser.parseValue()
            print("Test19:", v)
            // -> list([atom("X-HEADER"), string("value with spaces")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 20
        do {
            var parser = IMAPParser(input: "(SEQ 1:10)")
            let v = try parser.parseValue()
            print("Test20:", v)
            // -> list([atom("SEQ"), atom("1:10")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 21
        do {
            var parser = IMAPParser(input: "(SEQ 1:*)")
            let v = try parser.parseValue()
            print("Test21:", v)
            // -> list([atom("SEQ"), atom("1:*")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 22
        do {
            var parser = IMAPParser(input: "(BYTES {5}\r\n12345)")
            let v = try parser.parseValue()
            print("Test22:", v)
            // -> list([atom("BYTES"), literal("12345")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 23
        do {
            var parser = IMAPParser(input: "(BYTES {0}\r\n\r\n)")
            let v = try parser.parseValue()
            print("Test23:", v)
            // -> list([atom("BYTES"), literal("")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 24
        do {
            var parser = IMAPParser(input: "(NAME \"A \\\"quoted\\\" name\")")
            let v = try parser.parseValue()
            print("Test24:", v)
            // -> list([atom("NAME"), string("A \"quoted\" name")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 25
        do {
            var parser = IMAPParser(input: "(ATOM-with-dash value)")
            let v = try parser.parseValue()
            print("Test25:", v)
            // -> list([atom("ATOM-with-dash"), atom("value")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 26
        do {
            var parser = IMAPParser(input: "(A.B C.D)")
            let v = try parser.parseValue()
            print("Test26:", v)
            // -> list([atom("A.B"), atom("C.D")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 27
        do {
            var parser = IMAPParser(input: "(ADDR user@domain.com)")
            let v = try parser.parseValue()
            print("Test27:", v)
            // -> list([atom("ADDR"), atom("user@domain.com")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 28
        do {
            var parser = IMAPParser(input: "(FLAGS (\\Seen \\Answered \\Flagged))")
            let v = try parser.parseValue()
            print("Test28:", v)
            // -> list([atom("FLAGS"), list([atom("\Seen"), atom("\Answered"), atom("\Flagged")])])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 29
        do {
            var parser = IMAPParser(input: "(MULTI (ONE) (TWO) (THREE))")
            let v = try parser.parseValue()
            print("Test29:", v)
            // -> list([atom("MULTI"), list([atom("ONE")]), list([atom("TWO")]), list([atom("THREE")])])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 30
        do {
            var parser = IMAPParser(input: "([ALERTS (\"Message 1\" \"Message 2\")])")
            let v = try parser.parseValue()
            print("Test30:", v)
            // -> list([list([atom("ALERTS"), list(string("Message 1"), string("Message 2"))])])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 31
        do {
            var parser = IMAPParser(input: "(X {4}\r\ntest)")
            let v = try parser.parseValue()
            print("Test31:", v)
            // -> list([atom("X"), literal("test")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 32
        do {
            var parser = IMAPParser(input: "(X {1}\r\na)")
            let v = try parser.parseValue()
            print("Test32:", v)
            // -> list([atom("X"), literal("a")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 33
        do {
            var parser = IMAPParser(input: "(COMPLEX (A B (C D (E F))))")
            let v = try parser.parseValue()
            print("Test33:", v)
            // -> deeply nested lists
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 34
        do {
            var parser = IMAPParser(input: "(EMPTY_LIST ())")
            let v = try parser.parseValue()
            print("Test34:", v)
            // -> list([atom("EMPTY_LIST"), list([])])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 35
        do {
            var parser = IMAPParser(input: "NIL")
            let v = try parser.parseValue()
            print("Test35:", v)
            // -> NIL
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 36
        do {
            var parser = IMAPParser(input: "(NIL NIL)")
            let v = try parser.parseValue()
            print("Test36:", v)
            // -> list([NIL, NIL])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 37
        do {
            var parser = IMAPParser(input: "(MIXED \"text\" {6}\r\nbinary\r\n)")
            let v = try parser.parseValue()
            print("Test37:", v)
            // -> mixed quoted + literal
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 38
        do {
            var parser = IMAPParser(input: "(FLAG \\*)")
            let v = try parser.parseValue()
            print("Test38:", v)
            // -> list([atom("FLAG"), atom("\*")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 39
        do {
            var parser = IMAPParser(input: "(SEQ *)")
            let v = try parser.parseValue()
            print("Test39:", v)
            // -> list([atom("SEQ"), atom("*")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 40
        do {
            var parser = IMAPParser(input: "(UID 0)")
            let v = try parser.parseValue()
            print("Test40:", v)
            // -> number zero inside list
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 41
        do {
            var parser = IMAPParser(input: "(ESCAPED \"Line1\\\\Line2\")")
            let v = try parser.parseValue()
            print("Test41:", v)
            // -> string "Line1\\Line2"
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 42
        do {
            var parser = IMAPParser(input: "(PAIR (K V))")
            let v = try parser.parseValue()
            print("Test42:", v)
            // -> list([atom("PAIR"), list([atom("K"), atom("V")])])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 43
        do {
            var parser = IMAPParser(input: "(MULT {3}\r\nabc TWO)")
            let v = try parser.parseValue()
            print("Test43:", v)
            // -> list([atom("MULT"), literal("abc"), atom("TWO")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 44
        do {
            var parser = IMAPParser(input: "(A B\tC\r\nD)")
            let v = try parser.parseValue()
            print("Test44:", v)
            // -> whitespace variants
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 45
        do {
            var parser = IMAPParser(input: "(SEQ (1 2 3 4 5))")
            let v = try parser.parseValue()
            print("Test45:", v)
            // -> nested numeric list
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 46
        do {
            var parser = IMAPParser(input: "(TAG \"\")")
            let v = try parser.parseValue()
            print("Test46:", v)
            // -> empty quoted string
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 47
        do {
            var parser = IMAPParser(input: "(TAG \"\\\"escaped\\\"\")")
            let v = try parser.parseValue()
            print("Test47:", v)
            // -> quoted string containing quotes
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 48
        do {
            var parser = IMAPParser(input: "(HDR (\"From\" \"To\" \"Subject\"))")
            let v = try parser.parseValue()
            print("Test48:", v)
            // -> header fields list
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 49
        do {
            var parser = IMAPParser(input: "(LIST (\"a\" \"b\") (\"c\"))")
            let v = try parser.parseValue()
            print("Test49:", v)
            // -> multiple quoted lists
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 50
        do {
            var parser = IMAPParser(input: "(RANGE 5:7 10:12)")
            let v = try parser.parseValue()
            print("Test50:", v)
            // -> atoms with colon ranges
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 51
        do {
            var parser = IMAPParser(input: "(\"weird\\ name\")")
            let v = try parser.parseValue()
            print("Test51:", v)
            // -> quoted containing backslash-space
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 52
        do {
            var parser = IMAPParser(input: "(PAREN_IN_STRING \"(not a list)\")")
            let v = try parser.parseValue()
            print("Test52:", v)
            // -> parenthesis inside quoted string
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 53
        do {
            var parser = IMAPParser(input: "(BRACKETS [not parsed])")
            let v = try parser.parseValue()
            print("Test53:", v)
            // -> square brackets treated as atoms inside list
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 54
        do {
            var parser = IMAPParser(input: "([CODE OK])")
            let v = try parser.parseValue()
            print("Test54:", v)
            // -> square bracket list with atom
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 55
        do {
            var parser = IMAPParser(input: "([CODE NIL])")
            let v = try parser.parseValue()
            print("Test55:", v)
            // -> square bracket list with NIL
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 56
        do {
            var parser = IMAPParser(input: "(SEQ 1234567890)")
            let v = try parser.parseValue()
            print("Test56:", v)
            // -> large number
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 57
        do {
            var parser = IMAPParser(input: "(KEY \"multi\\nline\")")
            let v = try parser.parseValue()
            print("Test57:", v)
            // -> quoted with escaped newline char sequence
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 58
        do {
            var parser = IMAPParser(input: "(KEY \"multi\\r\\nline\")")
            let v = try parser.parseValue()
            print("Test58:", v)
            // -> quoted with CRLF escapes
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 59
        do {
            var parser = IMAPParser(input: "(A \"x\\\"y\" B)")
            let v = try parser.parseValue()
            print("Test59:", v)
            // -> quoted contains escaped quote
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 60
        do {
            var parser = IMAPParser(input: "(M {7}\r\n1234567)")
            let v = try parser.parseValue()
            print("Test60:", v)
            // -> literal length 7
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 61
        do {
            var parser = IMAPParser(input: "(M {2}\r\nOK\r\n)")
            let v = try parser.parseValue()
            print("Test61:", v)
            // -> literal with trailing CRLF inside value
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 62
        do {
            var parser = IMAPParser(input: "(EMPTY ( ) )")
            let v = try parser.parseValue()
            print("Test62:", v)
            // -> list with inner empty parentheses and spacing
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 63
        do {
            var parser = IMAPParser(input: "(DOT .dot)")
            let v = try parser.parseValue()
            print("Test63:", v)
            // -> atom starting with dot is allowed in parser as atom
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 64
        do {
            var parser = IMAPParser(input: "(DASH -dash)")
            let v = try parser.parseValue()
            print("Test64:", v)
            // -> atom with leading dash
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 65
        do {
            var parser = IMAPParser(input: "(UNDERSCORE _val)")
            let v = try parser.parseValue()
            print("Test65:", v)
            // -> atom with underscore
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 66
        do {
            var parser = IMAPParser(input: "(PLUS +plus)")
            let v = try parser.parseValue()
            print("Test66:", v)
            // -> atom with plus
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 67
        do {
            var parser = IMAPParser(input: "(STAR *)")
            let v = try parser.parseValue()
            print("Test67:", v)
            // -> star atom
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 68
        do {
            var parser = IMAPParser(input: "(ESCSEQ \"\\t\\r\\n\")")
            let v = try parser.parseValue()
            print("Test68:", v)
            // -> quoted with escaped control chars
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 69
        do {
            var parser = IMAPParser(input: "(MULTI {4}\r\n1234 {3}\r\nabc)")
            let v = try parser.parseValue()
            print("Test69:", v)
            // -> two consecutive literals
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 70
        do {
            var parser = IMAPParser(input: "(A B C D E F G H I J K L M N O P Q R S T U V W X Y Z)")
            let v = try parser.parseValue()
            print("Test70:", v)
            // -> long atom list
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 71
        do {
            var parser = IMAPParser(input: "(NUMS 1 2 3 4 5 6 7 8 9 10)")
            let v = try parser.parseValue()
            print("Test71:", v)
            // -> sequence of numbers
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 72
        do {
            var parser = IMAPParser(input: "(MIX {5}\r\nHELLO \"Q\" NIL 42)")
            let v = try parser.parseValue()
            print("Test72:", v)
            // -> mixed literal, quoted, NIL and number
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 73
        do {
            var parser = IMAPParser(input: "(MULTI (A) \"B\" {3}\r\nCDE)")
            let v = try parser.parseValue()
            print("Test73:", v)
            // -> mixed parts
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 74
        do {
            var parser = IMAPParser(input: "(ADDRLIST (\"a@b\" \"c@d\"))")
            let v = try parser.parseValue()
            print("Test74:", v)
            // -> addresses in quoted strings
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 75
        do {
            var parser = IMAPParser(input: "(EMPTYBRACKETS [])")
            let v = try parser.parseValue()
            print("Test75:", v)
            // -> empty square brackets as atom contents
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 76
        do {
            var parser = IMAPParser(input: "([A B C])")
            let v = try parser.parseValue()
            print("Test76:", v)
            // -> square bracket list with multiple atoms
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 77
        do {
            var parser = IMAPParser(input: "(COMPILE \\Seen \\* ABC)")
            let v = try parser.parseValue()
            print("Test77:", v)
            // -> flags with backslash and star
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 78
        do {
            var parser = IMAPParser(input: "(SEQ 1:3,5)")
            let v = try parser.parseValue()
            print("Test78:", v)
            // -> atom containing comma
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 79
        do {
            var parser = IMAPParser(input: "(QUOTES \"a'b\\\"c\")")
            let v = try parser.parseValue()
            print("Test79:", v)
            // -> mix single quote and escaped double quote
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 80
        do {
            var parser = IMAPParser(input: "(LITINLINE {6}\r\ninline!)")
            let v = try parser.parseValue()
            print("Test80:", v)
            // -> inline literal
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 81
        do {
            var parser = IMAPParser(input: "(MULTI (ONE TWO) [X Y] {4}\r\nDONE)")
            let v = try parser.parseValue()
            print("Test81:", v)
            // -> mixed parentheses, brackets and literal
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 82
        do {
            var parser = IMAPParser(input: "(ESCAPED-BACKSLASH \"\\\\\")")
            let v = try parser.parseValue()
            print("Test82:", v)
            // -> quoted that contains a single backslash
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 83
        do {
            var parser = IMAPParser(input: "(NAME \"name with ) parenthesis\")")
            let v = try parser.parseValue()
            print("Test83:", v)
            // -> right paren inside quoted string
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 84
        do {
            var parser = IMAPParser(input: "(NAME \"name with ( parenthesis\")")
            let v = try parser.parseValue()
            print("Test84:", v)
            // -> left paren inside quoted string
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 85
        do {
            var parser = IMAPParser(input: "(M {3}\r\nab\n)")
            let v = try parser.parseValue()
            print("Test85:", v)
            // -> literal containing a newline inside (3 bytes: 'a','b','\n')
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 86
        do {
            var parser = IMAPParser(input: "(SEQ 00001)")
            let v = try parser.parseValue()
            print("Test86:", v)
            // -> number with leading zeros parsed as Int or atom depending on Int initializer
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 87
        do {
            var parser = IMAPParser(input: "(FLAGS ())")
            let v = try parser.parseValue()
            print("Test87:", v)
            // -> empty flags list
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 88
        do {
            var parser = IMAPParser(input: "(MULT (A) (B) (C (D) E) )")
            let v = try parser.parseValue()
            print("Test88:", v)
            // -> complex nested groups
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 89
        do {
            var parser = IMAPParser(input: "(TAG \"Esc\\\"aped\\\"Quote\")")
            let v = try parser.parseValue()
            print("Test89:", v)
            // -> quoted with multiple escaped quotes
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 90
        do {
            var parser = IMAPParser(input: "(MANY {10}\r\n0123456789)")
            let v = try parser.parseValue()
            print("Test90:", v)
            // -> literal of 10 bytes numeric
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 91
        do {
            var parser = IMAPParser(input: "(COMMA a,b,c)")
            let v = try parser.parseValue()
            print("Test91:", v)
            // -> atom containing commas
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 92
        do {
            var parser = IMAPParser(input: "(SEMI a;b;c)")
            let v = try parser.parseValue()
            print("Test92:", v)
            // -> atom containing semicolons
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 93
        do {
            var parser = IMAPParser(input: "(SLASH a/b/c)")
            let v = try parser.parseValue()
            print("Test93:", v)
            // -> atom containing slashes
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 94
        do {
            var parser = IMAPParser(input: "(PERCENT a% b%)")
            let v = try parser.parseValue()
            print("Test94:", v)
            // -> atoms with percent
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 95
        do {
            var parser = IMAPParser(input: "(AMPERSAND a&b)")
            let v = try parser.parseValue()
            print("Test95:", v)
            // -> atom with ampersand
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 96
        do {
            var parser = IMAPParser(input: "(EQ =equals=)")
            let v = try parser.parseValue()
            print("Test96:", v)
            // -> atom with equals
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 97
        do {
            var parser = IMAPParser(input: "(TILDE ~tilda)")
            let v = try parser.parseValue()
            print("Test97:", v)
            // -> atom with tilde
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 98
        do {
            var parser = IMAPParser(input: "(DQUOTE \"\\\"embedded\\\"\")")
            let v = try parser.parseValue()
            print("Test98:", v)
            // -> embedded double quotes
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 99
        do {
            var parser = IMAPParser(input: "(MULTILIT {3}\r\none {3}\r\ntwo {5}\r\nthree)")
            let v = try parser.parseValue()
            print("Test99:", v)
            // -> multiple literals concatenated in same list
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 100
        do {
            var parser = IMAPParser(input: "(NIL \"\" {0}\r\n)")
            let v = try parser.parseValue()
            print("Test100:", v)
            // -> NIL, empty quoted and empty literal
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 101
        do {
            var parser = IMAPParser(input: "(ENCODED \"=?utf-8?Q?Hello_World?=\")")
            let v = try parser.parseValue()
            print("Test101:", v)
            // -> encoded-word inside quoted string (left for MIME decoder)
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 102
        do {
            var parser = IMAPParser(input: "(COLON a:b:c)")
            let v = try parser.parseValue()
            print("Test102:", v)
            // -> atom with multiple colons
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 103
        do {
            var parser = IMAPParser(input: "(DOTSTART .start)")
            let v = try parser.parseValue()
            print("Test103:", v)
            // -> atom starting with dot
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 104
        do {
            var parser = IMAPParser(input: "(DOMAIN example.com)")
            let v = try parser.parseValue()
            print("Test104:", v)
            // -> domain-like atom
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 105
        do {
            var parser = IMAPParser(input: "(EMAIL \"user\\@host\")")
            let v = try parser.parseValue()
            print("Test105:", v)
            // -> quoted containing @ escaped in string
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 106
        do {
            var parser = IMAPParser(input: "(BRACKETS-IN-LIST ([A] [B] [C]))")
            let v = try parser.parseValue()
            print("Test106:", v)
            // -> square bracket atoms inside a parenthesized list
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 107
        do {
            var parser = IMAPParser(input: "(EMPTYNEST (()))")
            let v = try parser.parseValue()
            print("Test107:", v)
            // -> double empty nested list
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 108
        do {
            var parser = IMAPParser(input: "(SPACES    A    B   C  )")
            let v = try parser.parseValue()
            print("Test108:", v)
            // -> irregular spaces between atoms
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 109
        do {
            var parser = IMAPParser(input: "(TAB\tA\tB\tC)")
            let v = try parser.parseValue()
            print("Test109:", v)
            // -> tabs as separators
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 110
        do {
            var parser = IMAPParser(input: "(CRLF\r\nA\r\nB\r\n)")
            let v = try parser.parseValue()
            print("Test110:", v)
            // -> explicit CRLF sequences in input
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 111
        do {
            var parser = IMAPParser(input: "(MIXEDLITS {4}\r\nABCD {2}\r\nEF)")
            let v = try parser.parseValue()
            print("Test111:", v)
            // -> adjacent literals
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 112
        do {
            var parser = IMAPParser(input: "(QUOTED-ESCAPE \"\\\\\\\"\\\\\")")
            let v = try parser.parseValue()
            print("Test112:", v)
            // -> combination of backslash and escaped quote
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 113
        do {
            var parser = IMAPParser(input: "(STARLIKE \\*)")
            let v = try parser.parseValue()
            print("Test113:", v)
            // -> backslash-star flag
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 114
        do {
            var parser = IMAPParser(input: "(PREFIX pre:suf post: )")
            let v = try parser.parseValue()
            print("Test114:", v)
            // -> atoms with colon suffix
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 115
        do {
            var parser = IMAPParser(input: "(NUMSEQ 1 2 3 4 5 {1}\r\n6)")
            let v = try parser.parseValue()
            print("Test115:", v)
            // -> numbers and literal combined
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 116
        do {
            var parser = IMAPParser(input: "(EMPTY-STR \"\")")
            let v = try parser.parseValue()
            print("Test116:", v)
            // -> empty quoted string value
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 117
        do {
            var parser = IMAPParser(input: "([RESPCODE X Y Z])")
            let v = try parser.parseValue()
            print("Test117:", v)
            // -> response code with multiple atoms
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 118
        do {
            var parser = IMAPParser(input: "(MIXED {3}\r\n123 \"q\" NIL 9)")
            let v = try parser.parseValue()
            print("Test118:", v)
            // -> literal then quoted, NIL and number
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 119
        do {
            var parser = IMAPParser(input: "(MULTI-DEPTH (A (B (C (D (E))))))")
            let v = try parser.parseValue()
            print("Test119:", v)
            // -> very deep nesting
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 120
        do {
            var parser = IMAPParser(input: "(SPECIALS !#$%^&*()[]{})")
            let v = try parser.parseValue()
            print("Test120:", v)
            // -> special characters inside atom allowed by our atom rule (some may be split)
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 121
        do {
            var parser = IMAPParser(input: "(LONGATOM this-is-a-very-long-atom-with-many-chars-0123456789)")
            let v = try parser.parseValue()
            print("Test121:", v)
            // -> long atom
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 122
        do {
            var parser = IMAPParser(input: "(ENCLOSE [PERMFLAGS (\\Deleted \\Seen)])")
            let v = try parser.parseValue()
            print("Test122:", v)
            // -> square bracket list nested inside parent list
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 123
        do {
            var parser = IMAPParser(input: "(EMPTY-LITERAL {0}\r\n)")
            let v = try parser.parseValue()
            print("Test123:", v)
            // -> explicit empty literal
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 124
        do {
            var parser = IMAPParser(input: "(SOMEKEY \"with \\t tab\" \"and \\n newline\")")
            let v = try parser.parseValue()
            print("Test124:", v)
            // -> quoted with escape sequences
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 125
        do {
            var parser = IMAPParser(input: "(MIXED2 (\"a\" b) {4}\r\ncdef)")
            let v = try parser.parseValue()
            print("Test125:", v)
            // -> mixed quoted, atom and literal
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 126
        do {
            var parser = IMAPParser(input: "(UNUSUAL atom_with#hash)")
            let v = try parser.parseValue()
            print("Test126:", v)
            // -> atom containing hash
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 127
        do {
            var parser = IMAPParser(input: "(ESCAPED-SEQ \"\\\\n\")")
            let v = try parser.parseValue()
            print("Test127:", v)
            // -> backslash n literal in quoted -> \\n
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 128
        do {
            var parser = IMAPParser(input: "(PATH inbox/Subfolder)")
            let v = try parser.parseValue()
            print("Test128:", v)
            // -> slash in atom
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 129
        do {
            var parser = IMAPParser(input: "(PERCENT-TEST %ABC %DEF)")
            let v = try parser.parseValue()
            print("Test129:", v)
            // -> percent prefixed atoms
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 130
        do {
            var parser = IMAPParser(input: "([X-GM-MSGID 1234567890])")
            let v = try parser.parseValue()
            print("Test130:", v)
            // -> gmail-specific resp code style
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 131
        do {
            var parser = IMAPParser(input: "(TABS\t\"a\"\t{1}\r\nb)")
            let v = try parser.parseValue()
            print("Test131:", v)
            // -> tabs between token types
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 132
        do {
            var parser = IMAPParser(input: "(MIXED3 \"a\\\"b\" {2}\r\ncd NIL)")
            let v = try parser.parseValue()
            print("Test132:", v)
            // -> quoted with escaped quote and literal and NIL
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 133
        do {
            var parser = IMAPParser(input: "(SEQ-STAR *)")
            let v = try parser.parseValue()
            print("Test133:", v)
            // -> star as atom
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 134
        do {
            var parser = IMAPParser(input: "(RANGE 2:4 6:8)")
            let v = try parser.parseValue()
            print("Test134:", v)
            // -> two ranges
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 135
        do {
            var parser = IMAPParser(input: "(\"empty\" \" \")")
            let v = try parser.parseValue()
            print("Test135:", v)
            // -> quoted with a single space
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 136
        do {
            var parser = IMAPParser(input: "(SYM !@#$)")
            let v = try parser.parseValue()
            print("Test136:", v)
            // -> symbols inside atom (treated as atom content)
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 137
        do {
            var parser = IMAPParser(input: "(DOT-END end.)")
            let v = try parser.parseValue()
            print("Test137:", v)
            // -> atom ending with dot
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 138
        do {
            var parser = IMAPParser(input: "(COMMENT (This is a comment))")
            let v = try parser.parseValue()
            print("Test138:", v)
            // -> parenthesized comment-like atom sequence
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 139
        do {
            var parser = IMAPParser(input: "(MULTILINE {11}\r\nHello\nWorld\r\n)")
            let v = try parser.parseValue()
            print("Test139:", v)
            // -> literal containing LF inside
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 140
        do {
            var parser = IMAPParser(input: "(MIX-LTR \"abc\" \"def\" {3}\r\nghi)")
            let v = try parser.parseValue()
            print("Test140:", v)
            // -> multiple text tokens
        } catch {
            assertionFailure(error.localizedDescription)
        }
    }

    static func chatGptTestsImapLanguages() {

        // --- Test 214: русский текст (quoted string)
        do {
            var parser = IMAPParser(input: "(BODY \"Привет мир\")")
            let v = try parser.parseValue()
            print("Test214:", v)
            // -> list([atom("BODY"), string("Привет мир")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 215: китайский текст (quoted string)
        do {
            var parser = IMAPParser(input: "(BODY \"你好 世界\")")
            let v = try parser.parseValue()
            print("Test215:", v)
            // -> list([atom("BODY"), string("你好 世界")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 216: арабский текст (quoted string)
        do {
            var parser = IMAPParser(input: "(BODY \"مرحبا بالعالم\")")
            let v = try parser.parseValue()
            print("Test216:", v)
            // -> list([atom("BODY"), string("مرحبا بالعالم")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 217: японский текст (literal)
        do {
            let input = "(BODY {15}\r\nこんにちは世界\r\n)"
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test217:", v)
            // -> list([atom("BODY"), literal("こんにちは世界")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 218: emoji в quoted string
        do {
            var parser = IMAPParser(input: "(BODY \"🌍🚀✨\")")
            let v = try parser.parseValue()
            print("Test218:", v)
            // -> list([atom("BODY"), string("🌍🚀✨")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 219: смешанный список с разными языками
        do {
            let input = "(MIX \"Привет\" \"你好\" \"مرحبا\" \"Hello\" \"🌍🚀✨\")"
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test219:", v)
            // -> list([atom("MIX"), string("Привет"), string("你好"), string("مرحبا"), string("Hello"), string("🌍🚀✨")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 220: NIL внутри многоязычного списка
        do {
            let input = "(MIXED \"Привет\" NIL \"مرحبا\" NIL \"Hello\")"
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test220:", v)
            // -> list([atom("MIXED"), string("Привет"), NIL, string("مرحبا"), NIL, string("Hello")])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 221: большой вложенный список с разными языками
        do {
            let input = "(ALL (RU {12}\r\nПривет мир\r\n) (CN \"你好世界\") (AR \"مرحبا بالعالم\") (LAT \"Curaçao résumé\") (EMOJI \"🌍🚀✨\"))"
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test221:", v)
            // -> list([atom("ALL"),
            //      list([atom("RU"), literal("Привет мир")]),
            //      list([atom("CN"), string("你好世界")]),
            //      list([atom("AR"), string("مرحبا بالعالم")]),
            //      list([atom("LAT"), string("Curaçao résumé")]),
            //      list([atom("EMOJI"), string("🌍🚀✨")])])
        } catch {
            assertionFailure(error.localizedDescription)
        }

        // --- Test 222: пустой список в многоязычном контексте
        do {
            let input = "(LANGS () \"Привет\" \"你好\" \"مرحبا\")"
            var parser = IMAPParser(input: input)
            let v = try parser.parseValue()
            print("Test222:", v)
            // -> list([atom("LANGS"), list([]), string("Привет"), string("你好"), string("مرحبا")])
        } catch {
            assertionFailure(error.localizedDescription)
        }
    }
}

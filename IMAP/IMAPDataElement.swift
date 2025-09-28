import Foundation

// ============================
// IMAP AST (Abstract Syntax Tree)
// ============================
// RFC 3501 §4: базовые синтаксические элементы
public enum IMAPValue {
    case atom(String)     // RFC 3501 §4.1.2 Atom — произвольное слово без пробелов и спецсимволов
    case number(Int)      // RFC 3501 §4.1.3 Number — целое число
    case string(String)   // RFC 3501 §4.3 Quoted string — строка в кавычках
    case literal(Data)    // RFC 3501 §4.3 Literal — строка фиксированной длины {N}\r\n<data>
    case nilValue         // RFC 3501 §4.5 NIL — специальное значение (null)
    case list([IMAPValue])// RFC 3501 §4.4 Parenthesized list — список в скобках
}

// MARK: - CustomStringConvertible

extension IMAPValue: CustomStringConvertible {

    // Для удобства печати дерева в консоль
    public var description: String {
        switch self {
        case .atom(let string):
            return "atom(\(string))"
        case .number(let number):
            return "number(\(number))"
        case .string(let string):
            return "string(\"\(string)\")"
        case .literal(let data):
            if let string = String(data: data, encoding: .utf8) {
                return "literal(\"\(string)\")"
            } else {
                assertionFailure("Литерал поврежден. Скорее всего неправильно расчитаны байты в {N}\r\n<data>")

                // Памятка расчета байт:
                //
                // \r и \n - 1 байт
                // Латинская буква - 1 байт
                // Кирилическая буква - 2 байта
                // Иероглифы - 3 байта
                // Эмодзи - 4 байта
                return "literal(<\(data.count) bytes>)"
            }
        case .nilValue:
            return "NIL"
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
enum ASCII {
    static let lparen: UInt8    = 0x28 // (
    static let rparen: UInt8    = 0x29 // )
    static let quote: UInt8     = 0x22 // "
    static let backslash: UInt8 = 0x5C // \
    static let lbrace: UInt8    = 0x7B // {
    static let rbrace: UInt8    = 0x7D // }
    static let lbracket: UInt8  = 0x5B // [
    static let rbracket: UInt8  = 0x5D // ]
    static let space: UInt8     = 0x20 // пробел
    static let tab: UInt8       = 0x09 // \t
    static let cr: UInt8        = 0x0D // \r
    static let lf: UInt8        = 0x0A // \n
    static let zero: UInt8      = 0x30 // '0'
    static let nine: UInt8      = 0x39 // '9'
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

public typealias IMAPParser = IMAPParserAlgo<TokenizerV2>

public struct IMAPParserAlgo<T: Tokenizable> {
    private var tokenizer: T
    private var lookahead: Token = .eof // текущий токен

    public init(input: String) {
        self.tokenizer = T(input)
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
        case .atom(let atomValue):
            advance()
            // RFC 3501 §4.5 — NIL
            if atomValue.count == 3
                // Не используем .uppercased(), тк он создает новый String и портит производительность
                && (atomValue == "NIL" || atomValue == "Nil" || atomValue == "nil")
            {
                return .nilValue
            }
            // RFC 3501 §4.1.3 — число
            if let numberValue = Int(atomValue) {

                // Если строка состоит из нескольких цифр
                // и первый символ в строке 0, то считаем, что это атом, а не число
                if atomValue.count > 1 && atomValue.first == "0" {
                    return .atom(atomValue)
                }

                return .number(numberValue)
            }
            // обычный атом
            return .atom(atomValue)

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

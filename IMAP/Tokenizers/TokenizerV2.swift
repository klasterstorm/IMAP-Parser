//
//  TokenizerV2.swift
//  IMAP
//
//  Created by Женя Баян on 29.09.2025.
//

import Foundation

/// Ускоренный токенайзер по сравнению с `TokenizerV1`
///
/// Что даёт этот патч (оценка):
/// - Меньше аллокаций: skipWhitespace, readDecimal, поиск границ делают idx-движение без выделений.
/// - Меньше копий: создаём Data/String только один раз на токен (и только когда это нужно). При отсутствии escape-символов вообще нет промежуточных массивов.
/// - Быстрее парсинг числа: экономия на создании String + парсинге через Int(...).
/// - Производительность: на типичном входе выигрыш может быть значительным (несколько раз быстрее при большом количестве коротких токенов), особенно если парсируешь много сообщений.
public struct TokenizerV2: Tokenizable {
    private let bytes: [UInt8]
    private let count: Int
    private var idx: Int = 0

    public init(_ input: String) {
        self.bytes = Array(input.utf8)
        self.count = bytes.count
        self.idx = 0
    }

    @inline(__always) private mutating func peekByte() -> UInt8? {
        return idx < count ? bytes[idx] : nil
    }

    @inline(__always) private mutating func advance(_ n: Int = 1) {
        idx = Swift.min(count, idx + n)
    }

    // Быстрое пропускание пробелов/таб/CR/LF без аллокаций
    @inline(__always) private mutating func skipWhitespace() {
        var i = idx
        while i < count {
            let b = bytes[i]
            if b == ASCII.space || b == ASCII.tab || b == ASCII.cr || b == ASCII.lf {
                i += 1
            } else { break }
        }
        idx = i
    }

    // Прочитать десятичное число на лету; возвращает -1 если цифр нет
    @inline(__always) private mutating func readDecimal() -> Int {
        var n = 0
        var any = false
        while idx < count {
            let b = bytes[idx]
            if b >= ASCII.zero && b <= ASCII.nine {
                any = true
                n = n * 10 + Int(b - ASCII.zero)
                idx += 1
            } else { break }
        }
        return any ? n : -1
    }

    // Пропустить либо реальный CRLF / LF, либо текстовую последовательность "\r\n" (байты '\' 'r' '\' 'n') или "\n"
    @inline(__always) private mutating func consumeCRLFOrEscaped() {
        if idx >= count { return }
        let b = bytes[idx]
        if b == ASCII.cr {
            idx += 1
            if idx < count && bytes[idx] == ASCII.lf { idx += 1 }
            return
        }
        if b == ASCII.lf {
            idx += 1
            return
        }
        // текстовое "\r\n" -> bytes: backslash, 'r', backslash, 'n'
        if idx + 3 < count &&
            bytes[idx] == ASCII.backslash &&
            bytes[idx + 1] == 0x72 && // 'r'
            bytes[idx + 2] == ASCII.backslash &&
            bytes[idx + 3] == 0x6E {   // 'n'
            idx += 4
            return
        }
        // текстовое "\n" -> backslash, 'n'
        if idx + 1 < count &&
            bytes[idx] == ASCII.backslash &&
            bytes[idx + 1] == 0x6E { // 'n'
            idx += 2
            return
        }
    }

    mutating public func nextToken() -> Token {
        skipWhitespace()
        guard idx < count else { return .eof }
        let b = bytes[idx]

        // single-char tokens
        if b == ASCII.lparen { idx += 1; return .lparen }
        if b == ASCII.rparen { idx += 1; return .rparen }
        if b == ASCII.lbracket { idx += 1; return .lbracket }
        if b == ASCII.rbracket { idx += 1; return .rbracket }

        // Quoted string "..."
        if b == ASCII.quote {
            idx += 1 // skip opening quote
            let start = idx
            var hasEscape = false

            // First pass: find closing quote, detect if escapes exist
            while idx < count {
                let ch = bytes[idx]
                if ch == ASCII.quote {
                    break
                }
                if ch == ASCII.backslash {
                    hasEscape = true
                    idx += 2 // skip backslash and following byte (if present)
                } else {
                    idx += 1
                }
            }
            let end = idx
            // if closing quote present, skip it
            if idx < count && bytes[idx] == ASCII.quote { idx += 1 }

            if !hasEscape {
                // Нет экранирования — можно декодировать напрямую из среза
                let s = String(decoding: bytes[start..<end], as: UTF8.self)
                return .quoted(s)
            } else {
                // Есть escape-символы — собрать результирующий буфер
                var out: [UInt8] = []
                out.reserveCapacity(end - start)
                var i = start
                while i < end {
                    let ch = bytes[i]
                    if ch == ASCII.backslash {
                        i += 1
                        if i < end {
                            out.append(bytes[i])
                            i += 1
                        }
                    } else {
                        out.append(ch); i += 1
                    }
                }
                let s = String(decoding: out, as: UTF8.self)
                return .quoted(s)
            }
        }

        // Literal {N}\r\n<data>
        if b == ASCII.lbrace {
            idx += 1 // skip '{'
            // read decimal length (on the fly)
            let len = readDecimal()
            // expect '}' — if present, skip it
            if idx < count && bytes[idx] == ASCII.rbrace { idx += 1 }

            // after '}' there should be CRLF (or escaped)
            consumeCRLFOrEscaped()

            // read exactly len bytes (or until EOF)
            let start = idx
            let end = Swift.min(count, start + max(0, len))
            let data = Data(bytes[start..<end])
            idx = end

            // DO NOT consume CRLF after the literal body here (it's part of following tokens)
            return .literal(data)
        }

        // Atom: read until a delimiter — без доп. аллокаций
        let start = idx
        while idx < count {
            let ch = bytes[idx]
            if ch == ASCII.lparen || ch == ASCII.rparen ||
                ch == ASCII.lbracket || ch == ASCII.rbracket ||
                ch == ASCII.quote  || ch == ASCII.lbrace ||
                ch == ASCII.space  || ch == ASCII.tab      ||
                ch == ASCII.cr     || ch == ASCII.lf {
                break
            }
            idx += 1
        }
        let atom = String(decoding: bytes[start..<idx], as: UTF8.self)
        return .atom(atom)
    }
}

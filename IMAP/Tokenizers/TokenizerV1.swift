//
//  TokenizerV1.swift
//  IMAP
//
//  Created by Женя Баян on 29.09.2025.
//

import Foundation

public protocol Tokenizable {

    init(_ input: String)

    mutating func nextToken() -> Token
}

public struct TokenizerV1: Tokenizable {
    private let bytes: [UInt8]   // Весь вход IMAP как массив байтов
    private var idx: Int = 0     // Текущая позиция

    public init(_ input: String) {
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
    mutating public func nextToken() -> Token {
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
            !(
                ch == ASCII.lparen   || ch == ASCII.rparen   ||
                ch == ASCII.lbracket || ch == ASCII.rbracket ||
                ch == ASCII.quote    || ch == ASCII.lbrace   ||
                ch == ASCII.space    || ch == ASCII.tab      ||
                ch == ASCII.cr       || ch == ASCII.lf
            )
        }
        let atomStr = String(decoding: atomBytes, as: UTF8.self)
        return .atom(atomStr)
    }
}

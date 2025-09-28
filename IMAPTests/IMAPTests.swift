//
//  IMAPTests.swift
//  IMAPTests
//
//  Created by Женя Баян on 16.09.2025.
//

import XCTest
import IMAP

final class IMAPTests: XCTestCase {

    func test_simpleListWithAtoms() throws {
        var parser = IMAPParser(input: "(FLAGS (\\Seen \\Answered) UID 4829013)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("FLAGS"),
            .list([.atom("\\Seen"), .atom("\\Answered")]),
            .atom("UID"),
            .number(4829013)
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_envelopeWithQuotedStringsAndNil() throws {
        var parser = IMAPParser(
            input: "(ENVELOPE (\"Mon, 7 May 2024 12:34:56 +0000\" \"Subject here\" (\"From\" NIL \"from@example.com\") NIL NIL) NIL NIL)"
        )
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("ENVELOPE"),
            .list([
                .string("Mon, 7 May 2024 12:34:56 +0000"),
                .string("Subject here"),
                .list([.string("From"), .nilValue, .string("from@example.com")]),
                .nilValue,
                .nilValue
            ]),
            .nilValue,
            .nilValue
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_bodystructureLike() throws {
        let example = """
        ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 1152 23) (\"IMAGE\" \"JPEG\" (\"NAME\" \"pic.jpg\") NIL NIL \"BASE64\" 34567) \"MIXED\")
        """
        var parser = IMAPParser(input: example)
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .list([
                .string("TEXT"),
                .string("PLAIN"),
                .list([.string("CHARSET"), .string("UTF-8")]),
                .nilValue,
                .nilValue,
                .string("7BIT"),
                .number(1152),
                .number(23)
            ]),
            .list([
                .string("IMAGE"),
                .string("JPEG"),
                .list([.string("NAME"), .string("pic.jpg")]),
                .nilValue,
                .nilValue,
                .string("BASE64"),
                .number(34567)
            ]),
            .string("MIXED")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_literalUtf8RussianText() throws {
        let input = "(BODY {21}\r\nФывап Апыап\r\n)"
        var parser = IMAPParser(input: input)
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("BODY"),
            .literal("Фывап Апыап".data(using: .utf8)!)
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_permanentFlagsSquareBrackets() throws {
        let input = #"([PERMANENTFLAGS (\Answered \Flagged \Deleted \Seen \Draft \*)])"#
        var parser = IMAPParser(input: input)
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .list([
                .atom("PERMANENTFLAGS"),
                .list([
                    .atom("\\Answered"),
                    .atom("\\Flagged"),
                    .atom("\\Deleted"),
                    .atom("\\Seen"),
                    .atom("\\Draft"),
                    .atom("\\*")
                ])
            ])
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_simple_list_with_atoms() throws {
        let input = "(FLAGS (\\Seen \\Answered) UID 4829013)"
        var parser = IMAPParser(input: input)
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("FLAGS"),
            .list([
                .atom("\\Seen"),
                .atom("\\Answered")
            ]),
            .atom("UID"),
            .number(4829013)
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_emptyList() throws {
        var parser = IMAPParser(input: "()")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_numberZero() throws {
        var parser = IMAPParser(input: "0")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.number(0)
        XCTAssertEqual(parsed.description, expected.description)
    }

    // Если строка начинается с 0, то считаем, что это атом, а не цифра.
    func test_atomDigits() throws {
        var parser = IMAPParser(input: "0123456789")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("0123456789")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_numberLarge() throws {
        var parser = IMAPParser(input: "123456789")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.number(123456789)
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_nilUppercase() throws {
        var parser = IMAPParser(input: "NIL")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.nilValue
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_nilLowercase() throws {
        var parser = IMAPParser(input: "nil")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.nilValue
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomSimple() throws {
        var parser = IMAPParser(input: "ATOM")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("ATOM")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithSpecialChars() throws {
        var parser = IMAPParser(input: "FOO.BAR-BAZ_")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("FOO.BAR-BAZ_")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_quotedString() throws {
        var parser = IMAPParser(input: "\"hello world\"")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.string("hello world")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_quotedEscapedQuote() throws {
        var parser = IMAPParser(input: "\"hello\\\"world\"")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.string("hello\"world")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_literalEmpty() throws {
        var parser = IMAPParser(input: "{0}\r\n")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.literal("".data(using: .utf8)!)
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_literalText() throws {
        var parser = IMAPParser(input: "{5}\r\nhello")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.literal("hello".data(using: .utf8)!)
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithAtoms() throws {
        var parser = IMAPParser(input: "(ONE TWO THREE)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("ONE"), .atom("TWO"), .atom("THREE")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_nestedList() throws {
        var parser = IMAPParser(input: "(A (B C) D)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("A"),
            .list([.atom("B"), .atom("C")]),
            .atom("D")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithNil() throws {
        var parser = IMAPParser(input: "(NIL FOO)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .nilValue, .atom("FOO")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithNumbers() throws {
        var parser = IMAPParser(input: "(1 2 3)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .number(1), .number(2), .number(3)
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithStrings() throws {
        var parser = IMAPParser(input: "(\"a\" \"b\" \"c\")")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .string("a"), .string("b"), .string("c")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomCaseInsensitive() throws {
        var parser = IMAPParser(input: "ok")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("ok")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_multipleAtomsWithSpaces() throws {
        var parser = IMAPParser(input: "FOO   BAR   BAZ")
        let v1 = try parser.parseValue()
        let v2 = try parser.parseValue()
        let v3 = try parser.parseValue()
        XCTAssertEqual(v1.description, IMAPValue.atom("FOO").description)
        XCTAssertEqual(v2.description, IMAPValue.atom("BAR").description)
        XCTAssertEqual(v3.description, IMAPValue.atom("BAZ").description)
    }

    func test_largeNestedList() throws {
        var parser = IMAPParser(input: "(A (B (C (D E))))")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("A"),
            .list([
                .atom("B"),
                .list([
                    .atom("C"),
                    .list([
                        .atom("D"), .atom("E")
                    ])
                ])
            ])
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithDigits() throws {
        var parser = IMAPParser(input: "ATOM123")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("ATOM123")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithSymbols() throws {
        var parser = IMAPParser(input: "A-B+C*D")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("A-B+C*D")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithMixedTypes() throws {
        var parser = IMAPParser(input: "(1 \"two\" THREE NIL)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .number(1), .string("two"), .atom("THREE"), .nilValue
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_deeplyNestedEmptyLists() throws {
        var parser = IMAPParser(input: "(((())))")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .list([
                .list([
                    .list([])
                ])
            ])
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_emptyQuotedString() throws {
        var parser = IMAPParser(input: "\"\"")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.string("")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_singleSpaceQuotedString() throws {
        var parser = IMAPParser(input: "\" \"")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.string(" ")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomUppercaseLetters() throws {
        var parser = IMAPParser(input: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomLowercaseLetters() throws {
        var parser = IMAPParser(input: "abcdefghijklmnopqrstuvwxyz")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("abcdefghijklmnopqrstuvwxyz")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_stringWithEscapedBackslash() throws {
        var parser = IMAPParser(input: "\"foo\\\\bar\"")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.string("foo\\bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listOfEmptyLists() throws {
        var parser = IMAPParser(input: "(() () ())")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .list([]), .list([]), .list([])
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listOfQuotedStrings() throws {
        var parser = IMAPParser(input: "(\"one\" \"two\" \"three\")")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .string("one"), .string("two"), .string("three")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listOfMixedAtomsAndStrings() throws {
        var parser = IMAPParser(input: "(FOO \"bar\" BAZ)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("FOO"), .string("bar"), .atom("BAZ")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithNestedEmptyLists() throws {
        var parser = IMAPParser(input: "(A () B () C)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("A"), .list([]), .atom("B"), .list([]), .atom("C")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_deeplyNestedMixed() throws {
        var parser = IMAPParser(input: "(A (B (C (\"D\" E))))")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("A"),
            .list([
                .atom("B"),
                .list([
                    .atom("C"),
                    .list([.string("D"), .atom("E")])
                ])
            ])
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithDashAndDot() throws {
        var parser = IMAPParser(input: "foo-bar.baz")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo-bar.baz")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithUnderscore() throws {
        var parser = IMAPParser(input: "foo_bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo_bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithMixedCase() throws {
        var parser = IMAPParser(input: "FoObAr")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("FoObAr")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithSlash() throws {
        var parser = IMAPParser(input: "foo/bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo/bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithEqualAndQuestion() throws {
        var parser = IMAPParser(input: "foo=bar?baz")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo=bar?baz")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithAsterisk() throws {
        var parser = IMAPParser(input: "foo*bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo*bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithPercent() throws {
        var parser = IMAPParser(input: "foo%bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo%bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithExclamation() throws {
        var parser = IMAPParser(input: "foo!bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo!bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithAmpersand() throws {
        var parser = IMAPParser(input: "foo&bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo&bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithQuotesInsideString() throws {
        var parser = IMAPParser(input: "\"foo \\\"bar\\\" baz\"")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.string("foo \"bar\" baz")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithBackslashesInsideString() throws {
        var parser = IMAPParser(input: "\"foo\\\\bar\\\\baz\"")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.string("foo\\bar\\baz")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithNilAndNumbers() throws {
        var parser = IMAPParser(input: "(NIL 42 999)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([.nilValue, .number(42), .number(999)])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithAtomsAndQuotedStrings() throws {
        var parser = IMAPParser(input: "(FOO \"bar\" BAZ \"qux\")")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("FOO"), .string("bar"), .atom("BAZ"), .string("qux")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithMultipleNil() throws {
        var parser = IMAPParser(input: "(NIL NIL NIL)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([.nilValue, .nilValue, .nilValue])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithNestedQuotedStrings() throws {
        var parser = IMAPParser(input: "(\"a\" (\"b\" (\"c\")))")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .string("a"),
            .list([
                .string("b"),
                .list([.string("c")])
            ])
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_numberSingleDigit() throws {
        var parser = IMAPParser(input: "7")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.number(7)
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_numberMultipleDigits() throws {
        var parser = IMAPParser(input: "98765")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.number(98765)
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_quotedStringWithNumbers() throws {
        var parser = IMAPParser(input: "\"12345\"")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.string("12345")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_quotedStringWithSymbols() throws {
        var parser = IMAPParser(input: "\"!@#$%^&*()\"")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.string("!@#$%^&*()")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomSingleLetter() throws {
        var parser = IMAPParser(input: "X")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("X")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithCombination() throws {
        var parser = IMAPParser(input: "foo-bar_baz.qux")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo-bar_baz.qux")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_nestedEmptyLists() throws {
        var parser = IMAPParser(input: "((()) (()))")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .list([.list([])]),
            .list([.list([])])
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithAtomsNumbersStrings() throws {
        var parser = IMAPParser(input: "(FOO 123 \"bar\")")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("FOO"), .number(123), .string("bar")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomCaseSensitivity() throws {
        var parser = IMAPParser(input: "TeSt")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("TeSt")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithMixedSymbols() throws {
        var parser = IMAPParser(input: "foo+bar=baz/qux")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo+bar=baz/qux")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listOnlyNIL() throws {
        var parser = IMAPParser(input: "(NIL)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([.nilValue])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_doubleQuotedStrings() throws {
        var parser = IMAPParser(input: "(\"foo\" \"bar\")")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([.string("foo"), .string("bar")])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_multipleNumbers() throws {
        var parser = IMAPParser(input: "(10 20 30 40)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .number(10), .number(20), .number(30), .number(40)
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithAtomAndNil() throws {
        var parser = IMAPParser(input: "(FOO NIL)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([.atom("FOO"), .nilValue])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithQuotedEmptyString() throws {
        var parser = IMAPParser(input: "(\"\")")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([.string("")])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_nestedListsMixed() throws {
        var parser = IMAPParser(input: "((FOO 123) (BAR \"baz\"))")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .list([.atom("FOO"), .number(123)]),
            .list([.atom("BAR"), .string("baz")])
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithHyphen() throws {
        var parser = IMAPParser(input: "foo-bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo-bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithDot() throws {
        var parser = IMAPParser(input: "foo.bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo.bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithColon() throws {
        var parser = IMAPParser(input: "foo:bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo:bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithComma() throws {
        var parser = IMAPParser(input: "foo,bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo,bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithSemicolon() throws {
        var parser = IMAPParser(input: "foo;bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo;bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithLessThan() throws {
        var parser = IMAPParser(input: "foo<bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo<bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithGreaterThan() throws {
        var parser = IMAPParser(input: "foo>bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo>bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithAtSign() throws {
        var parser = IMAPParser(input: "foo@bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo@bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithTilde() throws {
        var parser = IMAPParser(input: "foo~bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo~bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithGraveAccent() throws {
        var parser = IMAPParser(input: "foo`bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo`bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithCaret() throws {
        var parser = IMAPParser(input: "foo^bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo^bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithPipe() throws {
        var parser = IMAPParser(input: "foo|bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo|bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithBackslash() throws {
        var parser = IMAPParser(input: "foo\\\\bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo\\\\bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithQuote() throws {
        var parser = IMAPParser(input: "foo'bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo'bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_quotedStringWithSpaces() throws {
        var parser = IMAPParser(input: "\"foo bar baz\"")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.string("foo bar baz")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_quotedStringWithSymbols2() throws {
        var parser = IMAPParser(input: "\"foo!@#bar$%^baz\"")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.string("foo!@#bar$%^baz")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithNestedNIL() throws {
        var parser = IMAPParser(input: "(FOO (NIL) BAR)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("FOO"), .list([.nilValue]), .atom("BAR")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithEmptyStringAndAtom() throws {
        var parser = IMAPParser(input: "(\"\" FOO)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([.string(""), .atom("FOO")])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithEscapedBackslashes() throws {
        var parser = IMAPParser(input: "(\"foo\\\\bar\" \"baz\")")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .string("foo\\bar"), .string("baz")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithMixedEmptyAndNonEmpty() throws {
        var parser = IMAPParser(input: "(\"\" \"foo\" \"\")")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .string(""), .string("foo"), .string("")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_multipleNestedEmptyLists() throws {
        var parser = IMAPParser(input: "(() () (() ()))")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .list([]),
            .list([]),
            .list([.list([]), .list([])])
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithCombinationOfSymbols() throws {
        var parser = IMAPParser(input: "foo-bar_baz.qux+quux=quuz")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo-bar_baz.qux+quux=quuz")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_stringWithUnicode() throws {
        var parser = IMAPParser(input: "\"Привет\"")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.string("Привет")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithUnicodeStrings() throws {
        var parser = IMAPParser(input: "(\"你好\" \"мир\")")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .string("你好"), .string("мир")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithUnicodeAtoms() throws {
        var parser = IMAPParser(input: "(Привет こんにちは 你好)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("Привет"), .atom("こんにちは"), .atom("你好")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithEmoji() throws {
        var parser = IMAPParser(input: "foo😀bar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("foo😀bar")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_quotedStringWithEmoji() throws {
        var parser = IMAPParser(input: "\"hello🌍world\"")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.string("hello🌍world")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithEmojiStrings() throws {
        var parser = IMAPParser(input: "(\"😀\" \"😃\" \"😄\")")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .string("😀"), .string("😃"), .string("😄")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_nestedListWithEmoji() throws {
        var parser = IMAPParser(input: "(A (B (😀 😃)) C)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("A"),
            .list([.atom("B"), .list([.atom("😀"), .atom("😃")])]),
            .atom("C")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomWithMixedUnicodeAndEmoji() throws {
        var parser = IMAPParser(input: "Привет😀")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("Привет😀")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_quotedStringWithMixedUnicodeAndEmoji() throws {
        var parser = IMAPParser(input: "\"こんにちは😀\"")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.string("こんにちは😀")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithMixedUnicodeAndEmoji() throws {
        var parser = IMAPParser(input: "(\"Привет😀\" こんにちは 你好)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .string("Привет😀"),
            .atom("こんにちは"),
            .atom("你好")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_deeplyNestedUnicodeAndEmoji() throws {
        var parser = IMAPParser(input: "((\"😀\") ((\"Привет\")) (((\"こんにちは\"))))")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .list([.string("😀")]),
            .list([.list([.string("Привет")])]),
            .list([.list([.list([.string("こんにちは")])])])
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomLongString() throws {
        var parser = IMAPParser(input: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_quotedStringLong() throws {
        var parser = IMAPParser(input: "\"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789\"")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.string("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_complexNestedStructure() throws {
        var parser = IMAPParser(input: "(A (B (C (D (E (F (G (H (I (J))))))))))")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("A"),
            .list([
                .atom("B"),
                .list([
                    .atom("C"),
                    .list([
                        .atom("D"),
                        .list([
                            .atom("E"),
                            .list([
                                .atom("F"),
                                .list([
                                    .atom("G"),
                                    .list([
                                        .atom("H"),
                                        .list([.atom("I"), .list([.atom("J")])])
                                    ])
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_emptyInputThrowsError() throws {
        var parser = IMAPParser(input: "")
        XCTAssertThrowsError(try parser.parseValue())
    }

    func test_listWithLiteralEmpty() throws {
        var parser = IMAPParser(input: "({0}\r\n)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([.literal("".data(using: .utf8)!)])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_literalLong() throws {
        var parser = IMAPParser(input: "{62}\r\nABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.literal("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".data(using: .utf8)!)
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithLongValues() throws {
        var parser = IMAPParser(input: "(FOO \"ABCDEFGHIJKLMNOPQRSTUVWXYZ\" {3}\r\nbar)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("FOO"),
            .string("ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
            .literal("bar".data(using: .utf8)!)
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_emptyLiteralFollowedByAtom() throws {
        var parser = IMAPParser(input: "({0}\r\n FOO)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([.literal("".data(using: .utf8)!), .atom("FOO")])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_literalMultiline() throws {
        var parser = IMAPParser(input: "{12}\r\nhello\r\nworld")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.literal("hello\r\nworld".data(using: .utf8)!)
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_literalWithTabs() throws {
        var parser = IMAPParser(input: "{4}\r\nfoo\t")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.literal("foo\t".data(using: .utf8)!)
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithEmptyLiteralAndNil() throws {
        var parser = IMAPParser(input: "({0}\r\n NIL)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([.literal("".data(using: .utf8)!), .nilValue])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_nestedListWithMixedValues() throws {
        var parser = IMAPParser(input: "(A (B NIL \"foo\") (C 123 {3}\r\nbar))")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("A"),
            .list([.atom("B"), .nilValue, .string("foo")]),
            .list([.atom("C"), .number(123), .literal("bar".data(using: .utf8)!)])
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listComplexMixed() throws {
        var parser = IMAPParser(input: "(123 \"abc\" NIL (FOO {3}\r\nbar\r\n\r\n))")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .number(123),
            .string("abc"),
            .nilValue,
            .list([.atom("FOO"), .literal("bar".data(using: .utf8)!)])
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithMultipleLiterals() throws {
        var parser = IMAPParser(input: "({3}\r\nfoo {3}\r\nbar {3}\r\nbaz)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .literal("foo".data(using: .utf8)!),
            .literal("bar".data(using: .utf8)!),
            .literal("baz".data(using: .utf8)!)
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithQuotedAndLiteral() throws {
        var parser = IMAPParser(input: "(\"foo\" {3}\r\nbar)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .string("foo"),
            .literal("bar".data(using: .utf8)!)
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_literalWithSpaces() throws {
        var parser = IMAPParser(input: "{5}\r\nhello")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.literal("hello".data(using: .utf8)!)
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_literalWithCRLFAtEnd() throws {
        var parser = IMAPParser(input: "{2}\r\n\r\n")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.literal("\r\n".data(using: .utf8)!)
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listOfLiterals() throws {
        var parser = IMAPParser(input: "({3}\r\nfoo {3}\r\nbar)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .literal("foo".data(using: .utf8)!),
            .literal("bar".data(using: .utf8)!)
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_literalBody() throws {
        let input = "(BODY {11}\r\nHello World\r\n)"
        var parser = IMAPParser(input: input)
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("BODY"),
            .literal("Hello World".data(using: .utf8)!)
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_bodyHeaderFieldsLiteral() throws {
        let input = "(BODY[HEADER.FIELDS(Importance)]{20}\r\nImportance: high\r\n\r\n)"
        var parser = IMAPParser(input: input)
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("BODY"),
            .list([
                .atom("HEADER.FIELDS"),
                .list([.atom("Importance")])
            ]),
            .literal("Importance: high\r\n\r\n".data(using: .utf8)!)
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_literalWithCRLFInside() throws {
        var parser = IMAPParser(input: "{8}\r\nfoo\r\nbar")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.literal("foo\r\nbar".data(using: .utf8)!)
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithAtomsAndLiterals() throws {
        var parser = IMAPParser(input: "(FOO {3}\r\nbar BAZ)")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("FOO"), .literal("bar".data(using: .utf8)!), .atom("BAZ")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_quotedStringWithEscapedQuote() throws {
        let input = "(BODY \"=?utf-8?Q?App\\\")?=\")"
        var parser = IMAPParser(input: input)
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .atom("BODY"),
            .string("=?utf-8?Q?App\")?=")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_literalWithMixedUnicodeAndEmoji() throws {
        var parser = IMAPParser(input: "{10}\r\n你好😀")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.literal("你好😀".data(using: .utf8)!)
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_literalWithEmoji() throws {
        var parser = IMAPParser(input: "{12}\r\n😀😃😄")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.literal("😀😃😄".data(using: .utf8)!)
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_listWithEscapedQuotes() throws {
        var parser = IMAPParser(input: "(\"foo\\\"bar\" \"baz\")")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.list([
            .string("foo\"bar"), .string("baz")
        ])
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_literalWithUnicode() throws {
        var parser = IMAPParser(input: "{21}\r\nこんにちは世界")
        let parsed = try parser.parseValue()
        let expected = IMAPValue.literal("こんにちは世界".data(using: .utf8)!)
        XCTAssertEqual(parsed.description, expected.description)
    }

    func test_atomAllowedSymbols() throws {
        // RFC 3501 §4.1.2 — допустимые символы в atom
        let input = "!#$%&'*+-/=?^_`|~"
        var parser = IMAPParser(input: input)
        let parsed = try parser.parseValue()
        let expected = IMAPValue.atom("!#$%&'*+-/=?^_`|~")
        XCTAssertEqual(parsed.description, expected.description)
    }
}

// MARK: - Performance

extension IMAPTests {

    func test_parseLargeInputPerformance_v1() throws {
        let input = generate()

        measure {
            var parser = IMAPParserAlgo<TokenizerV1>(input: input)
            do {
                _ = try parser.parseValue()
            } catch {
                XCTFail("Парсер упал с ошибкой: \(error)")
            }
        }
    }

    func test_parseLargeInputPerformance_v2() throws {
        let input = generate()

        measure {
            var parser = IMAPParserAlgo<TokenizerV2>(input: input)
            do {
                _ = try parser.parseValue()
            } catch {
                XCTFail("Парсер упал с ошибкой: \(error)")
            }
        }
    }

    func generate() -> String {
        // Сгенерируем длинную строку: список из атомов и литералов
        var parts: [String] = []
        for i in 0..<1_000_000 {
            if i % 6 == 0 {
                parts.append("ATOM\(i)")
            } else if i % 6 == 1 {
                parts.append("{5}\r\nhello") // literal длиной 5
            } else if i % 6 == 2 {
                parts.append("\"quoted\(i)\"")
            } else if i % 6 == 3 {
                parts.append("\(i)")
            } else if i % 6 == 4 {
                parts.append("(A (B NIL \"foo\(i)\") (C \(i) {3}\r\nbar))")
            } else {
                parts.append("NIL")
            }
        }

        return "(\(parts.joined(separator: " ")))"
    }
}

import Foundation

/// 手写词法分析 + 递归下降求值，不依赖任何表达式库。
/// 支持：四则、括号、幂 ^ / **、mod、阶乘 !、百分号相对语义、
///      数量后缀（k w m b 千 万 亿）、进制字面量、常用函数与常量、隐式乘法。
enum Calculator {

    struct Output {
        let value: Double
        let display: String   // 带千分位，展示用
        let raw: String       // 不带千分位，复制用
        let extras: [String]  // 十六进制 / 二进制 / 万
    }

    enum Failure: Error {
        case empty
        case message(String)

        var text: String {
            switch self {
            case .empty: return ""
            case .message(let m): return m
            }
        }
    }

    // MARK: - 词法

    private enum Token: Equatable {
        case number(Double)
        case ident(String)
        case op(Character)
        case lparen
        case rparen
        case comma
    }

    private static let suffixes: [Character: Double] = [
        "k": 1e3, "w": 1e4, "m": 1e6, "b": 1e9, "千": 1e3, "万": 1e4, "亿": 1e8
    ]

    private static let constants: [String: Double] = [
        "pi": .pi, "π": .pi, "tau": .pi * 2, "e": M_E
    ]

    private static let unaryFns: [String: (Double) -> Double] = [
        "sin": sin, "cos": cos, "tan": tan,
        "asin": asin, "acos": acos, "atan": atan,
        "sinh": sinh, "cosh": cosh, "tanh": tanh,
        "ln": log, "log": log10, "log2": log2, "log10": log10,
        "sqrt": sqrt, "cbrt": cbrt, "abs": abs, "exp": exp,
        "round": { $0.rounded() }, "floor": floor, "ceil": ceil,
        "trunc": trunc, "sign": { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) }
    ]

    private static let variadicFns: [String: ([Double]) -> Double] = [
        "min": { $0.min() ?? .nan },
        "max": { $0.max() ?? .nan },
        "sum": { $0.reduce(0, +) },
        "avg": { $0.isEmpty ? .nan : $0.reduce(0, +) / Double($0.count) },
        "pow": { $0.count == 2 ? pow($0[0], $0[1]) : .nan }
    ]

    /// 只认 ASCII 数字。Swift 的 Character.isNumber 对「万 千 亿 一 二」这些 CJK 数字也返回 true，
    /// 不排除掉的话后缀会被吃进数字字面量。
    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    private static func isIdentChar(_ c: Character) -> Bool {
        c.isLetter || c == "_" || c == "π" || (c.unicodeScalars.first.map { $0.value >= 0x4E00 && $0.value <= 0x9FFF } ?? false)
    }

    private static func tokenize(_ input: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(input)
        var i = 0

        func peek(_ offset: Int = 0) -> Character? {
            let j = i + offset
            return j < chars.count ? chars[j] : nil
        }

        while i < chars.count {
            let c = chars[i]

            if c.isWhitespace { i += 1; continue }

            // 数字
            if isDigit(c) || (c == "." && (peek(1).map(isDigit) ?? false)) {
                // 进制字面量
                if c == "0", let n = peek(1), n == "x" || n == "X" {
                    i += 2
                    var digits = ""
                    while let d = peek(), d.isHexDigit || d == "_" { if d != "_" { digits.append(d) }; i += 1 }
                    guard let v = UInt64(digits, radix: 16) else { throw Failure.message("十六进制数字有误") }
                    tokens.append(.number(Double(v)))
                    continue
                }
                if c == "0", let n = peek(1), n == "b" || n == "B", let d = peek(2), d == "0" || d == "1" {
                    i += 2
                    var digits = ""
                    while let d = peek(), d == "0" || d == "1" || d == "_" { if d != "_" { digits.append(d) }; i += 1 }
                    guard let v = UInt64(digits, radix: 2) else { throw Failure.message("二进制数字有误") }
                    tokens.append(.number(Double(v)))
                    continue
                }

                var literal = ""
                while let d = peek() {
                    if isDigit(d) { literal.append(d); i += 1; continue }
                    if d == "_" { i += 1; continue }
                    // 逗号只有后面正好跟 3 位数字时才是千分位
                    if d == "," {
                        let following = (1...4).compactMap { peek($0) }
                        let firstThree = following.prefix(3)
                        let isGroup = firstThree.count == 3 && firstThree.allSatisfy(isDigit)
                            && !(following.count > 3 && isDigit(following[3]))
                        if isGroup { i += 1; continue }
                    }
                    break
                }
                if peek() == "." {
                    literal.append(".")
                    i += 1
                    while let d = peek(), isDigit(d) || d == "_" { if d != "_" { literal.append(d) }; i += 1 }
                }
                if let ex = peek(), ex == "e" || ex == "E",
                   let sign = peek(1), isDigit(sign) || sign == "+" || sign == "-" {
                    var j = i + 1
                    var expPart = "e"
                    if let s = peek(1), s == "+" || s == "-" { expPart.append(s); j += 1 }
                    var digits = ""
                    while j < chars.count, isDigit(chars[j]) { digits.append(chars[j]); j += 1 }
                    if !digits.isEmpty { literal += expPart + digits; i = j }
                }

                guard var value = Double(literal) else { throw Failure.message("数字 “\(literal)” 无法解析") }

                if let s = peek(), let factor = suffixes[Character(s.lowercased())] {
                    let next = peek(1)
                    // 后面不能紧跟字母，避免把 max 的 m 当成后缀
                    if next == nil || !isIdentChar(next!) {
                        value *= factor
                        i += 1
                    }
                }
                tokens.append(.number(value))
                continue
            }

            // 标识符
            if isIdentChar(c) {
                var name = ""
                while let d = peek(), isIdentChar(d) || isDigit(d) { name.append(d); i += 1 }
                tokens.append(.ident(name))
                continue
            }

            // 运算符与括号
            switch c {
            case "*":
                if peek(1) == "*" { tokens.append(.op("^")); i += 2 } else { tokens.append(.op("*")); i += 1 }
            case "+", "-", "/", "^", "%", "!":
                tokens.append(.op(c)); i += 1
            case "×": tokens.append(.op("*")); i += 1
            case "÷": tokens.append(.op("/")); i += 1
            case "(", "（": tokens.append(.lparen); i += 1
            case ")", "）": tokens.append(.rparen); i += 1
            case ",", "，": tokens.append(.comma); i += 1
            case "=", "＝": i += 1
            default:
                throw Failure.message("无法识别的字符 “\(c)”")
            }
        }
        return tokens
    }

    // MARK: - 语法

    private struct Parser {
        let tokens: [Token]
        var pos = 0
        let ans: Double

        /// value 与「它是不是裸百分数」——后者决定 200+10% 走相对语义
        typealias Node = (value: Double, percent: Bool)

        var current: Token? { pos < tokens.count ? tokens[pos] : nil }

        mutating func expression() throws -> Node {
            var left = try term()
            while case .op(let c)? = current, c == "+" || c == "-" {
                pos += 1
                let right = try term()
                let delta = right.percent ? left.value * right.value : right.value
                left = (c == "+" ? left.value + delta : left.value - delta, false)
            }
            return left
        }

        mutating func term() throws -> Node {
            var left = try unary()
            loop: while true {
                switch current {
                case .op(let c)? where c == "*" || c == "/":
                    pos += 1
                    let right = try unary()
                    left = (c == "*" ? left.value * right.value : left.value / right.value, false)
                case .ident(let name)? where name.lowercased() == "mod" || name.lowercased() == "rem":
                    pos += 1
                    let right = try unary()
                    left = (left.value.truncatingRemainder(dividingBy: right.value), false)
                // 隐式乘法：2(3+4)、3pi、2sqrt(9)；但「数字紧跟数字」是写错了，不做隐式乘法
                case .lparen?:
                    let right = try unary()
                    left = (left.value * right.value, false)
                case .ident(let name)? where !["mod", "rem"].contains(name.lowercased()):
                    let right = try unary()
                    left = (left.value * right.value, false)
                default:
                    break loop
                }
            }
            return left
        }

        mutating func unary() throws -> Node {
            if case .op(let c)? = current, c == "-" || c == "+" {
                pos += 1
                let node = try unary()
                return c == "-" ? (-node.value, node.percent) : node
            }
            return try power()
        }

        mutating func power() throws -> Node {
            let base = try postfix()
            if case .op("^")? = current {
                pos += 1
                let exponent = try unary()   // 右结合
                return (pow(base.value, exponent.value), false)
            }
            return base
        }

        mutating func postfix() throws -> Node {
            var node = try primary()
            while case .op(let c)? = current, c == "%" || c == "!" {
                pos += 1
                node = c == "%" ? (node.value / 100, true) : (Calculator.factorial(node.value), false)
            }
            return node
        }

        mutating func primary() throws -> Node {
            guard let token = current else { throw Failure.message("表达式不完整") }

            switch token {
            case .number(let v):
                pos += 1
                return (v, false)

            case .lparen:
                pos += 1
                let inner = try expression()
                guard case .rparen? = current else { throw Failure.message("缺少右括号") }
                pos += 1
                return (inner.value, false)

            case .ident(let rawName):
                pos += 1
                let name = rawName.lowercased()

                if let fn = unaryFns[name] {
                    let args = try arguments(defaultCount: 1)
                    guard args.count == 1 else { throw Failure.message("函数 \(name) 只接受 1 个参数") }
                    return (fn(args[0]), false)
                }
                if let fn = variadicFns[name] {
                    let args = try arguments(defaultCount: 1)
                    return (fn(args), false)
                }
                if let value = constants[name] ?? constants[rawName] {
                    return (value, false)
                }
                if name == "ans" { return (ans, false) }
                throw Failure.message("未知的名称 “\(rawName)”")

            case .rparen: throw Failure.message("多余的右括号")
            case .comma: throw Failure.message("逗号位置不对")
            case .op(let c): throw Failure.message("意外的符号 “\(c)”")
            }
        }

        /// 解析函数参数；没有括号时按 `sqrt 9` 处理
        mutating func arguments(defaultCount: Int) throws -> [Double] {
            guard case .lparen? = current else {
                return [try unary().value]
            }
            pos += 1
            var args: [Double] = []
            if case .rparen? = current { pos += 1; return args }
            while true {
                args.append(try expression().value)
                if case .comma? = current { pos += 1; continue }
                if case .rparen? = current { pos += 1; break }
                throw Failure.message("函数参数没有正确闭合")
            }
            return args
        }
    }

    private static func factorial(_ n: Double) -> Double {
        guard n >= 0, n == n.rounded(), n.isFinite else { return .nan }
        if n > 170 { return .infinity }
        return (1...max(Int(n), 1)).reduce(1.0) { $0 * Double($1) }
    }

    // MARK: - 对外接口

    static func evaluate(_ input: String, ans: Double = 0) -> Result<Output, Failure> {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("=") || text.hasSuffix("＝") { text.removeLast() }
        guard !text.isEmpty else { return .failure(.empty) }

        do {
            let tokens = try tokenize(text)
            var parser = Parser(tokens: tokens, ans: ans)
            let node = try parser.expression()
            if parser.pos < tokens.count { throw Failure.message("表达式后面有多余的内容") }
            guard node.value.isFinite || node.value.isInfinite, !node.value.isNaN else {
                throw Failure.message("结果不是一个有效数字")
            }
            let value = clean(node.value)
            return .success(Output(value: value,
                                   display: format(value, grouping: true),
                                   raw: format(value, grouping: false),
                                   extras: extras(for: value)))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.message("表达式有误"))
        }
    }

    /// 去掉 0.1+0.2 这类浮点误差尾巴
    static func clean(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        guard let rounded = Double(String(format: "%.12g", value)) else { return value }
        return rounded == 0 ? 0 : rounded
    }

    static func format(_ value: Double, grouping: Bool) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "∞" : "-∞" }

        let magnitude = abs(value)
        if magnitude != 0, magnitude < 1e-6 || magnitude >= 1e15 {
            return String(format: "%.6e", value)
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.maximumFractionDigits = 10
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func extras(for value: Double) -> [String] {
        var out: [String] = []
        if value != 0, value == value.rounded(), abs(value) <= 9_007_199_254_740_991 {
            let magnitude = Int(abs(value))
            out.append("HEX 0x" + String(magnitude, radix: 16).uppercased())
            if magnitude < 1 << 20 { out.append("BIN 0b" + String(magnitude, radix: 2)) }
        }
        if abs(value) >= 10_000 {
            out.append(format(clean(value / 10_000), grouping: true) + " 万")
        }
        return out
    }
}

import Foundation

let cases: [(String, String)] = [
    ("1+2*3", "7"), ("(1+2)*3", "9"), ("0.1+0.2", "0.3"),
    ("200+10%", "220"), ("200-10%", "180"), ("200*10%", "20"), ("50%", "0.5"),
    ("2^10", "1,024"), ("2**3^2", "512"), ("5!", "120"), ("10 mod 3", "1"),
    ("1.2w*3", "36,000"), ("3万+2千", "32,000"), ("1.5亿/3", "50,000,000"),
    ("sqrt(16)+abs(-2)", "6"), ("max(1,5,3)", "5"), ("avg(1,2,3,4)", "2.5"),
    ("min(3,1)", "1"), ("sum(1000,2000)", "3,000"), ("pow(2,10)", "1,024"),
    ("2(3+4)", "14"), ("1,234,567+1", "1,234,568"), ("12,345.67*2", "24,691.34"),
    ("0xff+0b1010", "265"), ("1e3+1", "1,001"), ("log(1000)", "3"),
    ("round(3.6)", "4"), ("100/3", "33.3333333333")
]

var failures = 0
for (input, expected) in cases {
    switch Calculator.evaluate(input, ans: 41) {
    case .success(let out):
        let mark = out.display == expected ? "✓" : "✗"
        if out.display != expected { failures += 1 }
        print("\(mark) \(input.padding(toLength: max(18, input.count), withPad: " ", startingAt: 0)) => \(out.display)\(out.display == expected ? "" : "  期望 \(expected)")")
    case .failure(let error):
        failures += 1
        print("✗ \(input) => 报错: \(error.text)")
    }
}

// ans 与错误处理
if case .success(let out) = Calculator.evaluate("ans+1", ans: 41), out.display == "42" {
    print("✓ ans+1                => 42")
} else { failures += 1; print("✗ ans 支持有问题") }

for bad in ["1+", "2+*3", "foo(1)", "1..2"] {
    if case .failure(let error) = Calculator.evaluate(bad), !error.text.isEmpty {
        print("✓ 拒绝非法输入 \(bad)：\(error.text)")
    } else {
        failures += 1
        print("✗ \(bad) 本应报错")
    }
}

print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
exit(failures == 0 ? 0 : 1)

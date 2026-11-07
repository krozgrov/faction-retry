import Foundation
@main struct FakeReader {
    static func main() {
        if CommandLine.arguments.contains("--hang") { sleep(60); return }
        _ = FileHandle.standardInput.readDataToEndOfFile()
        if CommandLine.arguments.contains("--bad-json") { print("bad"); return }
        let words = (0..<1500).map { ReadWord(text: "Line \($0) with enough characters to fill the pipe and test its drainage", rect: CGRect(x: 0.2, y: 0.4, width: 0.2, height: 0.02)) }
        FileHandle.standardOutput.write(try! JSONEncoder().encode(words))
    }
}

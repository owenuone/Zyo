// 向系统注册输入法，使其出现在「系统设置 › 键盘 › 输入法」列表中：swift Scripts/register.swift <App 路径>
import Carbon
import Foundation

let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let status = TISRegisterInputSource(url)
if status != noErr {
    FileHandle.standardError.write("TISRegisterInputSource 失败: \(status)\n".data(using: .utf8)!)
    exit(1)
}
print("已注册: \(CommandLine.arguments[1])")

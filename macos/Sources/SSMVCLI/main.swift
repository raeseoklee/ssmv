import AppKit
import Darwin
import Foundation
import MarkdownCore

@MainActor
func fail(_ message: String, code: Int32) -> Never {
  FileHandle.standardError.write(Data("ssmv: \(message)\n".utf8))
  exit(code)
}

@MainActor
func applicationURL() -> URL? {
  let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
  let containing = executable.deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  if containing.pathExtension == "app",
    Bundle(url: containing)?.bundleIdentifier == "io.github.irae.ssmv"
  {
    return containing
  }
  guard
    let installed = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: "io.github.irae.ssmv"),
    Bundle(url: installed)?.bundleIdentifier == "io.github.irae.ssmv",
    installed.lastPathComponent == "SSMV.app",
    !installed.path.contains("/.build/"), !installed.path.contains("/dist/")
  else { return nil }
  return installed
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
  print(
    """
    Usage: ssmv FILE | HTTPS_URL | - [--title TITLE]
    Open a Markdown file, public HTTPS Markdown URL, or UTF-8 standard input.
    --title is available only with '-'. Maximum input size: 16 MiB.
    Exit 0 confirms delivery only; download and rendering errors appear in SSMV.
    """)
  exit(0)
}
if arguments == ["--version"] {
  let version = applicationURL().flatMap {
    Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  }
  print("SSMV \(version ?? "development")")
  exit(0)
}
var input: String?
var title: String?
var index = 0
while index < arguments.count {
  let argument = arguments[index]
  if argument == "--title" {
    index += 1
    guard index < arguments.count, title == nil else {
      fail("--title requires one title.", code: 2)
    }
    title = arguments[index]
  } else {
    guard input == nil, argument == "-" || !argument.hasPrefix("-") else {
      fail("Provide one file, HTTPS URL, or '-'. Use --help for usage.", code: 2)
    }
    input = argument
  }
  index += 1
}
guard let input, title == nil || input == "-" else {
  fail("Use --title only with standard input.", code: 2)
}
let inbox = OpenRequestInbox()
var destination: URL
var staged = false
if input == "-" {
  guard isatty(STDIN_FILENO) == 0 else { fail("Pipe or redirect Markdown into ssmv -.", code: 2) }
  var data = Data()
  do {
    while let chunk = try FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
      guard data.count + chunk.count <= OpenRequestInbox.maximumTextBytes else {
        throw OpenRequestError.oversized
      }
      data.append(chunk)
    }
    try OpenRequestInbox.validateText(data)
  } catch { fail(error.localizedDescription, code: 3) }
  do {
    destination = try inbox.stageText(data, title: title)
    staged = true
  } catch { fail(error.localizedDescription, code: 4) }
} else if input.contains("://") {
  guard let url = URL(string: input) else { fail("Provide a valid HTTPS URL.", code: 2) }
  do { try OpenRequestInbox.validateURL(url) } catch {
    fail("Provide a public HTTPS URL without credentials.", code: 2)
  }
  do {
    destination = try inbox.stageRemote(url)
    staged = true
  } catch { fail(error.localizedDescription, code: 4) }
} else {
  destination = URL(fileURLWithPath: input).standardizedFileURL
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
    !isDirectory.boolValue,
    FileManager.default.isReadableFile(atPath: destination.path)
  else { fail("The input file does not exist or cannot be read.", code: 3) }
}
guard let app = applicationURL() else {
  if staged { try? inbox.discard(destination) }
  fail("SSMV is not installed. Install SSMV or run the command inside its app bundle.", code: 5)
}
if staged,
  Bundle(url: app)?.object(forInfoDictionaryKey: "SSMVOpenRequestVersion") as? Int != 1
{
  try? inbox.discard(destination)
  fail(
    "This SSMV app does not support this command's request protocol. Update the app and command together.",
    code: 5)
}
let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
configuration.createsNewApplicationInstance = false
let deliveryURL = destination
let isStaged = staged
NSWorkspace.shared.open([destination], withApplicationAt: app, configuration: configuration) {
  _, error in
  if error != nil {
    if isStaged { try? inbox.discard(deliveryURL) }
    FileHandle.standardError.write(
      Data("ssmv: macOS could not deliver the document to SSMV.\n".utf8))
    exit(5)
  }
  print("Sent to SSMV. Download and rendering status appear in the app.")
  exit(0)
}
RunLoop.main.run()

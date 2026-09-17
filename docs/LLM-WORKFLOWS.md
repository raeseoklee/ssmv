# Use SSMV with Codex, Claude, ChatGPT, and Gemini

[한국어](LLM-WORKFLOWS.ko.md) · [Back to README](../README.md)

The macOS edition of SSMV 0.5.0 or later can display Markdown from these tools through local files, copied text, or its `ssmv` command. No SSMV MCP server or provider-specific plugin is required.

| Where you work | How to open the result |
| --- | --- |
| Codex running locally on your Mac | Ask it to save a Markdown file and run `ssmv` |
| Claude Code or Gemini CLI on your Mac | Ask the agent to open its file, or use the commands below |
| ChatGPT, Claude chat, or Gemini chat | Copy Markdown into SSMV, or download a Markdown file |
| A cloud task, remote host, or container | Download the result to your Mac, then open it locally |

For the Windows preview, save or download the result as a Markdown file and open it in SSMV, or use clipboard import. The `ssmv` CLI examples below are macOS-only; see the [Windows guide](../windows/README.md) for supported handoffs.

## Before you start

Install or update SSMV using the [Homebrew instructions](../README.md#install), then check `ssmv --version` in Terminal. CLI examples below also require the corresponding AI tool to be installed and signed in. Run them in the project you want summarized. Provider usage and permissions still apply; SSMV supplies the viewer, not model access.

## Codex

In a local Codex task, use a request such as:

> Write the result as Markdown in a new file named `review.md` in this workspace. Keep code fences only around actual code examples. After saving, run `ssmv "review.md"` on this Mac to open it. If local app launch is unavailable, give me the file path instead.

For Codex CLI, capture the final response in a file and open it after successful completion:

```sh
codex exec "Summarize this project in Markdown. Return only the document, without an outer code fence. Do not modify project files." \
  -o codex-summary.md && ssmv "codex-summary.md"
```

The `-o` option writes the final message. See the [official Codex non-interactive guide](https://developers.openai.com/codex/noninteractive/). A cloud Codex task needs the download workflow below unless it has an explicit connection to your Mac.

## Claude Code

The same save-and-open request works in a local Claude Code session when file and command tools are available. For a single command:

```sh
claude -p "Summarize this project in Markdown. Return only the document, without an outer code fence. Do not modify project files." \
  --output-format text > claude-summary.md && ssmv "claude-summary.md"
```

Use text output rather than JSON or streaming events. See the [official Claude Code guide](https://code.claude.com/docs/en/headless). For Claude chat, use the clipboard or download workflow below.

## Gemini CLI

In a local Gemini CLI session, ask it to save and open the result, or run:

```sh
gemini -p "Summarize this project in Markdown. Return only the document, without an outer code fence. Do not modify project files." \
  --output-format text > gemini-summary.md && ssmv "gemini-summary.md"
```

The `-p` option runs a non-interactive request. See the [official Gemini CLI reference](https://geminicli.com/docs/cli/headless/). For Gemini chat, use the following workflow.

## ChatGPT, Claude chat, and Gemini chat

Use this workflow when the chat cannot run commands on your Mac:

1. Ask: “Return the document as Markdown in one copyable code block. Use headings, lists, and tables where helpful.” If the document includes fenced code examples, ask for a downloadable `.md` file instead when the client supports files.
2. Copy the contents of the Markdown block, without its outer fence.
3. In SSMV, choose **File → Open Clipboard as Markdown**.
4. To keep a separate file, choose **File → Save a Copy…**. You can also export it as PDF.

If the chat provides a downloadable Markdown file, save it on your Mac and use Finder → **Open With → SSMV**, or run `ssmv "/path/to/result.md"`. A cloud download link is not necessarily a public Markdown URL: download authenticated attachments through the chat first. Paste a URL into SSMV only when it directly serves public HTTPS Markdown or is a supported GitHub file link.

## Reuse the workflow

You can add this instruction to a local agent's project instructions when appropriate:

> When I ask to view a Markdown result in SSMV, save it to a new `.md` file and run `ssmv` with the quoted file path. If the command is unavailable, try `open -a SSMV` with that path. If app launch is blocked or the task runs remotely, provide the file for me to open locally.

The examples write files in the current folder; choose unused names to retain earlier results. `&&` opens SSMV only after the producer exits successfully. Prefer this file workflow for repeatable jobs. To import an existing result as an app-owned copy instead, run:

```sh
ssmv - --title "Project summary" < codex-summary.md
```

SSMV waits for the complete input and does not show tokens as they arrive. Inputs must be nonempty UTF-8 text of at most 16 MiB. Do not combine diagnostic output with Markdown using `2>&1`. CLI exit 0 confirms delivery to SSMV; later rendering errors appear in the app. Local files are reread with **⌘R** after changes; imported copies do not track the original or regenerate an answer.

If `ssmv` is not found, update the cask and reopen Terminal, or use `open -a SSMV "/path/to/result.md"`. If an agent's environment blocks app launch, run the command yourself in Terminal; no change to its sandbox is required.

Command options were checked against official documentation and locally installed CLI help on 2026-09-16.

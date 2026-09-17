# Markdown, at home on Windows.

A **native reader** for *focused reading*, with `C++20` and WinUI 3.
See the [SSMV project](https://github.com/raeseoklee/ssmv) for source and documentation.

| Read | Navigate | Keep |
| :--- | :---: | ---: |
| **Rich text** and `code` | Sidebar and headings | Your source files |
| Tables and quotes | Find matching sections | Reading position |
| Light and dark themes | Keyboard shortcuts | Markdown copies |

## Open and switch documents

- Press Ctrl+O to open Markdown files, or drop them from Explorer.
- Select a document in the sidebar tree and expand it to browse headings.
- Use Ctrl+F, then F3 or Shift+F3, to visit matching sections.
- Adjust text size with Ctrl++ and Ctrl+-, or reset it with Ctrl+0.

## Keep your list organized

Use the compact buttons beside **Documents** to add or remove files and toggle
headings. **View → Sort Documents** sorts by name. Clearing the list asks
for confirmation and leaves the original files on disk. The app restores your list
and reading position on restart.

## More ways to read

Use **File → Open from Clipboard** to read copied Markdown, **File → Save a Copy…**
to save it, and **Edit → Copy Document Text** to copy the document as plain text.
Ctrl+R reloads a file; F11 switches full screen. Choose System, Light or Dark under
**View → Appearance**. Each menu shows the available keyboard shortcuts.

> Keep the reader quiet, and let the document do the talking.

```cpp
#include <iostream>
int main() {
    std::cout << "Hello from SSMV!\n";
}
```

---

This Windows edition is in development. PDF export, remote Markdown loading and
stdin CLI delivery are still pending. Search finds sections rather than individual
occurrences; text selection is per block. Clipboard imports remain stored when
removed from the list.

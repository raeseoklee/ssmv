param([Parameter(Mandatory)][int]$Port, [switch]$Reopen, [scriptblock]$Capture)
$ErrorActionPreference = 'Stop'
# Inspect the live WebView2 page attached to the native window. WinUI's UIA
# tree on Server runners exposes window chrome but not this composition child.
$deadline = (Get-Date).AddSeconds(25)
do {
    try {
        $pages = Invoke-RestMethod "http://127.0.0.1:$Port/json/list" -TimeoutSec 2
        $page = $pages | Where-Object url -eq 'https://ssmv.invalid/viewer.html' | Select-Object -First 1
    } catch { $page = $null }
    if (!$page) { Start-Sleep -Milliseconds 150 }
} while (!$page -and (Get-Date) -lt $deadline)
if (!$page) { throw 'The native diagram viewer never navigated to the offline viewer page.' }
$socket = [Net.WebSockets.ClientWebSocket]::new()
$timeout = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(35))
try {
    $null = $socket.ConnectAsync([Uri]$page.webSocketDebuggerUrl, $timeout.Token).GetAwaiter().GetResult()
    $script:diagramCommandId = 0
    function Eval-Viewer([string]$Expression) {
        $id = ++$script:diagramCommandId
        $command = @{id=$id; method='Runtime.evaluate'; params=@{expression=$Expression; returnByValue=$true; awaitPromise=$true}} | ConvertTo-Json -Compress
        $bytes = [ArraySegment[byte]]::new([Text.Encoding]::UTF8.GetBytes($command))
        $null = $socket.SendAsync($bytes, [Net.WebSockets.WebSocketMessageType]::Text, $true, $timeout.Token).GetAwaiter().GetResult()
        $buffer = [ArraySegment[byte]]::new([byte[]]::new(8192))
        do {
            $stream = [IO.MemoryStream]::new()
            try {
                do {
                    $frame = $socket.ReceiveAsync($buffer, $timeout.Token).GetAwaiter().GetResult()
                    if ($frame.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'Diagram viewer closed unexpectedly.' }
                    $stream.Write($buffer.Array, 0, $frame.Count)
                } until ($frame.EndOfMessage)
                $reply = [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
            } finally { $stream.Dispose() }
        } until ($reply.id -eq $id)
        if ($reply.error -or $reply.result.exceptionDetails) { throw "Viewer command failed: $($reply | ConvertTo-Json -Depth 8)" }
        return $reply.result.result.value
    }
    function Wait-Viewer([string]$Expression) {
        $end = (Get-Date).AddSeconds(20)
        do { if (Eval-Viewer $Expression) { return }; Start-Sleep -Milliseconds 120 } while ((Get-Date) -lt $end)
        throw "Diagram viewer assertion timed out: $Expression"
    }
    Wait-Viewer "window.ssmvViewerReady === true && document.querySelector('#diagram svg')?.getBoundingClientRect().width > 0"
    if (!$Reopen) {
        $result = Eval-Viewer @'
(() => {
 const el = id => document.getElementById(id);
 el('actual-size').click(); el('zoom-in').click();
 if (el('zoom-value').textContent !== '125%') return false;
 el('zoom-out').click(); if (el('zoom-value').textContent !== '100%') return false;
 el('fit').click();
 el('query').focus(); el('query').value='실행'; el('query').dispatchEvent(new Event('input', {bubbles:true}));
 if (el('matches').textContent !== '1/2') return false;
 el('next').click(); if (el('matches').textContent !== '2/2') return false;
 el('previous').click();
 return el('matches').textContent === '1/2' && el('highlights').children.length === 2;
})()
'@
        if (!$result) { throw 'Zoom or Korean label navigation failed inside the native viewer.' }
        if ($Capture) { & $Capture }
        $null = Eval-Viewer "document.getElementById('fullscreen').click()"
        Wait-Viewer "document.getElementById('fullscreen').getAttribute('aria-label') === 'Exit full screen'"
        $null = Eval-Viewer "document.getElementById('fullscreen').click()"
        Wait-Viewer "document.getElementById('fullscreen').getAttribute('aria-label') === 'Enter full screen'"
    }
    $null = Eval-Viewer "setTimeout(() => document.getElementById('close').click(), 100); true"
} finally { $socket.Dispose(); $timeout.Dispose() }
$deadline = (Get-Date).AddSeconds(10)
do {
    try { $pages = Invoke-RestMethod "http://127.0.0.1:$Port/json/list" -TimeoutSec 2 }
    catch { $pages = @() }
    if (!($pages | Where-Object id -eq $page.id)) { return }
    Start-Sleep -Milliseconds 150
} while ((Get-Date) -lt $deadline)
throw 'Closing the diagram did not dispose its WebView2 page.'

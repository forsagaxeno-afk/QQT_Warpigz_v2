#requires -Version 5.1
<#
.SYNOPSIS
  Tiny read-only static file server for the WarRoom dashboard (QQT_Warpigz_v3). Zero installs:
  uses only Windows PowerShell 5.1 + .NET Framework (System.Net.Sockets.TcpListener).

.DESCRIPTION
  - Default: binds 127.0.0.1 only (this PC). No firewall prompt, no admin.
  - -Lan: binds 0.0.0.0 so phones/tablets on the home network (or VPN) can view it.
    An access token is then required for every non-localhost client (auto-generated
    and remembered in .dashboard-token next to this script; -NewToken rotates it).
  - GET/HEAD only. Serves ONLY files inside the dashboard folder with an allow-listed
    extension. No directory listings, no dotfiles, no symlinks/junctions, no path tricks.
  - Stop with Ctrl+C, by closing the window, or by creating a file named "stop.flag"
    next to this script (a Lua plugin can do that).

.EXAMPLE
  serve.bat                 (local only:   http://127.0.0.1:8765/)
  serve.bat -Lan            (home network: prints http://192.168.x.y:8765/t/TOKEN)
  serve.bat -Lan -Port 9000 -Root "C:\QQT\scripts\WarRoom\dashboard"
#>
[CmdletBinding()]
param(
    # Folder to serve. Default: ..\dashboard relative to this script (WarRoom\dashboard).
    [string]$Root,
    [ValidateRange(1024, 65535)][int]$Port = 8765,
    # Listen on all IPv4 interfaces (LAN / VPN access). Off by default.
    [switch]$Lan,
    # Advanced: bind one specific local IPv4 address instead (e.g. your Tailscale IP).
    [string]$BindAddress,
    # Use this token instead of the generated one (letters/digits, 12-64 chars).
    [string]$Token,
    # Generate a fresh token (invalidates old links/bookmarks on other devices).
    [switch]$NewToken,
    # LAN mode WITHOUT a token. Anyone on the network can read the dashboard.
    [switch]$NoToken,
    # Accept clients from non-private (public internet) addresses. Off by default.
    [switch]$AllowPublic,
    # Extra host names accepted in the Host header (e.g. "mypc.tailnet.ts.net").
    [string[]]$AllowHost = @(),
    # Serve files even if they are symlinks/junctions/cloud placeholders.
    [switch]$AllowReparsePoints,
    # Content-Security-Policy header value; pass '' to disable.
    [string]$Csp = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'",
    [switch]$Quiet
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- limits
$MaxHeaderBytes = 8192          # whole request head (request line + headers)
$MaxRequestLine = 2048
$MaxHeaderCount = 64
$MaxFileBytes   = 16MB
$ReadTimeoutMs  = 3000          # per socket read
$RequestDeadlineMs = 5000       # whole request head must arrive within this
$WriteTimeoutMs = 5000
$CookieName     = 'qqtdash'

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$StopFile  = Join-Path $ScriptDir 'stop.flag'
$TokenFile = Join-Path $ScriptDir '.dashboard-token'

$IsWin = ([IO.Path]::DirectorySeparatorChar -eq '\')
$PathCmp = if ($IsWin) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$Latin1 = [Text.Encoding]::GetEncoding(28591)

# Extension allow-list. Anything else is 404, even if it exists.
$Mime = @{
    '.html'  = 'text/html; charset=utf-8'
    '.htm'   = 'text/html; charset=utf-8'
    '.js'    = 'text/javascript; charset=utf-8'
    '.mjs'   = 'text/javascript; charset=utf-8'
    '.css'   = 'text/css; charset=utf-8'
    '.json'  = 'application/json; charset=utf-8'
    '.svg'   = 'image/svg+xml'
    '.png'   = 'image/png'
    '.jpg'   = 'image/jpeg'
    '.jpeg'  = 'image/jpeg'
    '.gif'   = 'image/gif'
    '.webp'  = 'image/webp'
    '.ico'   = 'image/x-icon'
    '.woff'  = 'font/woff'
    '.woff2' = 'font/woff2'
    '.map'   = 'application/json; charset=utf-8'
}
# Static assets that may be cached briefly; everything else (html/js/json/css) is no-store,
# so the data file the plugins rewrite is never served stale.
$Cacheable = @{ '.png' = 1; '.jpg' = 1; '.jpeg' = 1; '.gif' = 1; '.webp' = 1; '.ico' = 1; '.svg' = 1; '.woff' = 1; '.woff2' = 1 }

$Reasons = @{
    200 = 'OK'; 301 = 'Moved Permanently'; 302 = 'Found'; 400 = 'Bad Request'; 401 = 'Unauthorized'
    403 = 'Forbidden'; 404 = 'Not Found'; 405 = 'Method Not Allowed'; 408 = 'Request Timeout'
    413 = 'Payload Too Large'; 414 = 'URI Too Long'; 421 = 'Misdirected Request'
    431 = 'Request Header Fields Too Large'; 500 = 'Internal Server Error'; 503 = 'Service Unavailable'
}

function Write-Log([string]$msg) {
    if (-not $Quiet) { Write-Host ('{0:HH:mm:ss} {1}' -f (Get-Date), $msg) }
}

# ---------------------------------------------------------------- root folder
if (-not $Root) { $Root = Join-Path (Split-Path -Parent $ScriptDir) 'dashboard' }
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    Write-Host "Dashboard folder not found: $Root" -ForegroundColor Red
    Write-Host 'Pass the folder with -Root "C:\path\to\dashboard".'
    exit 2
}
$RootFull = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).ProviderPath)
if (-not $RootFull.EndsWith([string][IO.Path]::DirectorySeparatorChar)) { $RootFull += [IO.Path]::DirectorySeparatorChar }

# ---------------------------------------------------------------- bind address
if ($BindAddress) {
    $bindIp = $null
    if (-not [Net.IPAddress]::TryParse($BindAddress, [ref]$bindIp) -or $bindIp.AddressFamily -ne 'InterNetwork') {
        Write-Host "Invalid -BindAddress (IPv4 expected): $BindAddress" -ForegroundColor Red; exit 2
    }
} elseif ($Lan) {
    $bindIp = [Net.IPAddress]::Any
} else {
    $bindIp = [Net.IPAddress]::Loopback
}
$RemoteMode = -not [Net.IPAddress]::IsLoopback($bindIp)

# ---------------------------------------------------------------- token
function New-Token {
    # 20 chars of base32 = 100 bits. Upper-case A-Z2-7 keeps the URL QR "alphanumeric-mode" friendly.
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $bytes = New-Object byte[] 20
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $sb = New-Object Text.StringBuilder
    foreach ($b in $bytes) { [void]$sb.Append($alphabet[$b % 32]) }   # 256 % 32 == 0 -> unbiased
    $sb.ToString()
}

$AccessToken = $null
if ($RemoteMode -and -not $NoToken) {
    if ($Token) {
        if ($Token -notmatch '^[A-Za-z0-9]{12,64}$') { Write-Host '-Token must be 12-64 letters/digits.' -ForegroundColor Red; exit 2 }
        $AccessToken = $Token.ToUpperInvariant()
    } else {
        if (-not $NewToken -and (Test-Path -LiteralPath $TokenFile)) {
            $saved = ([IO.File]::ReadAllText($TokenFile)).Trim()
            if ($saved -match '^[A-Z2-7]{20}$') { $AccessToken = $saved }
        }
        if (-not $AccessToken) {
            $AccessToken = New-Token
            try { [IO.File]::WriteAllText($TokenFile, $AccessToken, [Text.Encoding]::ASCII) } catch { Write-Log "warning: could not save token file: $($_.Exception.Message)" }
        }
    }
}

function Test-TokenEqual([string]$a, [string]$b) {
    if ([string]::IsNullOrEmpty($a) -or [string]::IsNullOrEmpty($b)) { return $false }
    $x = [Text.Encoding]::ASCII.GetBytes($a.ToUpperInvariant())
    $y = [Text.Encoding]::ASCII.GetBytes($b.ToUpperInvariant())
    $diff = $x.Length -bxor $y.Length
    for ($i = 0; $i -lt $x.Length; $i++) { $diff = $diff -bor ($x[$i] -bxor $y[$i % $y.Length]) }
    return ($diff -eq 0)
}

# ---------------------------------------------------------------- host / client checks
$AllowedHostNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($h in @('localhost', [Environment]::MachineName, ([Environment]::MachineName + '.local'), ([Environment]::MachineName + '.lan'), ([Environment]::MachineName + '.home'))) { [void]$AllowedHostNames.Add($h) }
foreach ($h in $AllowHost) { if ($h) { [void]$AllowedHostNames.Add($h.Trim()) } }

function Test-HostHeader([string]$hostHdr) {
    # Blocks DNS-rebinding: a hostile web page cannot make your browser talk to this server
    # under an attacker-controlled name. IP literals and known local names are fine.
    if ([string]::IsNullOrEmpty($hostHdr)) { return $false }
    $name = $hostHdr
    if ($name.StartsWith('[')) {
        $end = $name.IndexOf(']'); if ($end -lt 0) { return $false }
        $name = $name.Substring(1, $end - 1)
    } else {
        $c = $name.LastIndexOf(':'); if ($c -ge 0) { $name = $name.Substring(0, $c) }
    }
    $name = $name.TrimEnd('.')
    $ip = $null
    if ([Net.IPAddress]::TryParse($name, [ref]$ip)) { return $true }
    return $AllowedHostNames.Contains($name)
}

function Test-PrivateClient([Net.IPAddress]$ip) {
    if ([Net.IPAddress]::IsLoopback($ip)) { return $true }
    if ($ip.AddressFamily -ne 'InterNetwork') { return $false }
    $b = $ip.GetAddressBytes()
    if ($b[0] -eq 10) { return $true }                                  # 10/8
    if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $true } # 172.16/12
    if ($b[0] -eq 192 -and $b[1] -eq 168) { return $true }              # 192.168/16
    if ($b[0] -eq 169 -and $b[1] -eq 254) { return $true }              # link-local
    if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return $true } # CGNAT 100.64/10 (Tailscale etc.)
    return $false
}

# ---------------------------------------------------------------- path resolution
$BadChars = [char[]]@([char]0, '\', ':', '*', '?', '"', '<', '>', '|', '~')
function Resolve-RequestPath([string]$rawPath) {
    # Returns @{Kind='file'|'dir'|'none'; Full=...; Ext=...}
    $none = @{ Kind = 'none' }
    try { $p = [Uri]::UnescapeDataString($rawPath) } catch { return $none }   # decode exactly once
    if ($p -match '[\x00-\x1f\x7f]') { return $none }
    if ($p.IndexOfAny($BadChars) -ge 0) { return $none }                     # \ : (ADS, drives) ~ (8.3 names)
    if (-not $p.StartsWith('/')) { return $none }
    $wantDirIndex = $p.EndsWith('/')
    if ($wantDirIndex) { $p += 'index.html' }
    $segs = $p.Substring(1).Split('/')
    if ($segs.Count -gt 8) { return $none }
    foreach ($s in $segs) {
        if ($s.Length -eq 0 -or $s.Length -gt 128) { return $none }          # '//' or silly long
        if ($s.StartsWith('.')) { return $none }                              # . .. and dotfiles
        if ($s.EndsWith('.') -or $s.EndsWith(' ')) { return $none }          # Win32 trailing trim tricks
        if ($s -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9]|CONIN\$|CONOUT\$)(\..*)?$') { return $none }
    }
    $rel = [string]::Join([string][IO.Path]::DirectorySeparatorChar, $segs)
    try { $full = [IO.Path]::GetFullPath([IO.Path]::Combine($RootFull, $rel)) } catch { return $none }
    if (-not $full.StartsWith($RootFull, $PathCmp)) { return $none }         # belt and braces

    if (-not $wantDirIndex -and [IO.Directory]::Exists($full)) {
        if (-not (Test-NoReparse $full)) { return $none }
        return @{ Kind = 'dir'; Full = $full }
    }
    $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
    if (-not $Mime.ContainsKey($ext)) { return $none }
    if (-not [IO.File]::Exists($full)) { return @{ Kind = 'missing'; Full = $full; Ext = $ext } }
    if (-not (Test-NoReparse $full)) { return $none }
    return @{ Kind = 'file'; Full = $full; Ext = $ext }
}

function Test-NoReparse([string]$full) {
    if ($AllowReparsePoints) { return $true }
    $cur = $full.TrimEnd([IO.Path]::DirectorySeparatorChar)
    $stop = $RootFull.TrimEnd([IO.Path]::DirectorySeparatorChar)
    while ($cur.Length -gt $stop.Length) {
        try { $attr = [IO.File]::GetAttributes($cur) } catch { return $false }
        if (($attr -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        $cur = [IO.Path]::GetDirectoryName($cur)
        if (-not $cur) { return $false }
    }
    return $true
}

# ---------------------------------------------------------------- HTTP plumbing
function Send-Response($ctx, [int]$code, [hashtable]$headers, [byte[]]$body) {
    if ($null -eq $body) { $body = New-Object byte[] 0 }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("HTTP/1.1 $code $($Reasons[$code])`r`n")
    [void]$sb.Append("Content-Length: $($body.Length)`r`n")
    [void]$sb.Append("Connection: close`r`n")
    [void]$sb.Append("X-Content-Type-Options: nosniff`r`n")
    [void]$sb.Append("Referrer-Policy: no-referrer`r`n")
    [void]$sb.Append("X-Frame-Options: SAMEORIGIN`r`n")
    [void]$sb.Append("Cross-Origin-Resource-Policy: same-origin`r`n")
    if ($Csp) { [void]$sb.Append("Content-Security-Policy: $Csp`r`n") }
    if (-not $headers) { $headers = @{} }
    if (-not $headers.ContainsKey('Content-Type')) { $headers['Content-Type'] = 'text/plain; charset=utf-8' }
    if (-not $headers.ContainsKey('Cache-Control')) { $headers['Cache-Control'] = 'no-store' }
    foreach ($k in $headers.Keys) { [void]$sb.Append("${k}: $($headers[$k])`r`n") }
    [void]$sb.Append("`r`n")
    $head = [Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $ctx.Stream.Write($head, 0, $head.Length)
    if (-not $ctx.Head -and $body.Length -gt 0) { $ctx.Stream.Write($body, 0, $body.Length) }
    $ctx.Stream.Flush()
    Write-Log ('{0,-15} {1,-4} {2} -> {3}' -f $ctx.Remote, $ctx.Method, $ctx.LogPath, $code)
}

function Send-Text($ctx, [int]$code, [string]$text, [hashtable]$headers) {
    Send-Response $ctx $code $headers ([Text.Encoding]::UTF8.GetBytes($text + "`n"))
}

function Read-RequestHead($stream) {
    # Returns @{Status='ok'; Text=...} or @{Status='closed'|'toolarge'|'timeout'}
    $buf = New-Object byte[] $MaxHeaderBytes
    $n = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if ($n -ge $MaxHeaderBytes) { return @{ Status = 'toolarge' } }
        if ($sw.ElapsedMilliseconds -gt $RequestDeadlineMs) { return @{ Status = 'timeout' } }
        try { $r = $stream.Read($buf, $n, $MaxHeaderBytes - $n) }
        catch { return @{ Status = 'timeout' } }             # IOException on ReceiveTimeout
        if ($r -le 0) { return @{ Status = 'closed' } }
        $scanFrom = [Math]::Max(0, $n - 3)
        $n += $r
        for ($i = $scanFrom; $i -le $n - 4; $i++) {
            if ($buf[$i] -eq 13 -and $buf[$i + 1] -eq 10 -and $buf[$i + 2] -eq 13 -and $buf[$i + 3] -eq 10) {
                return @{ Status = 'ok'; Text = $Latin1.GetString($buf, 0, $i) }
            }
        }
    }
}

function Get-Cookie([string]$cookieHdr, [string]$name) {
    if (-not $cookieHdr) { return $null }
    foreach ($part in $cookieHdr.Split(';')) {
        $kv = $part.Trim()
        $eq = $kv.IndexOf('=')
        if ($eq -gt 0 -and $kv.Substring(0, $eq) -eq $name) { return $kv.Substring($eq + 1) }
    }
    return $null
}

function Get-QueryValue([string]$query, [string]$name) {
    if (-not $query) { return $null }
    foreach ($pair in $query.Split('&')) {
        $eq = $pair.IndexOf('=')
        if ($eq -gt 0 -and $pair.Substring(0, $eq) -eq $name) {
            try { return [Uri]::UnescapeDataString($pair.Substring($eq + 1)) } catch { return $null }
        }
    }
    return $null
}

function Invoke-Client([Net.Sockets.TcpClient]$client) {
    $client.ReceiveTimeout = $ReadTimeoutMs
    $client.SendTimeout = $WriteTimeoutMs
    $client.NoDelay = $true
    $stream = $client.GetStream()
    $remoteIp = ([Net.IPEndPoint]$client.Client.RemoteEndPoint).Address
    if ($remoteIp.IsIPv4MappedToIPv6) { $remoteIp = $remoteIp.MapToIPv4() }
    $isLocalClient = [Net.IPAddress]::IsLoopback($remoteIp)
    $ctx = @{ Stream = $stream; Remote = $remoteIp.ToString(); Method = '-'; LogPath = '-'; Head = $false }

    if (-not $isLocalClient -and -not $AllowPublic -and -not (Test-PrivateClient $remoteIp)) {
        Send-Text $ctx 403 'Forbidden: only home-network / VPN addresses are allowed.' $null; return
    }

    $req = Read-RequestHead $stream
    switch ($req.Status) {
        'closed'   { return }
        'timeout'  { Send-Text $ctx 408 'Request timeout' $null; return }
        'toolarge' { Send-Text $ctx 431 'Request header too large' $null; return }
    }

    $lines = $req.Text.Split([string[]]@("`r`n"), [StringSplitOptions]::None)
    $reqLine = $lines[0]
    if ($reqLine.Length -gt $MaxRequestLine) { Send-Text $ctx 414 'URI too long' $null; return }
    if ($reqLine -notmatch '^([A-Z]{1,10}) (/[\x21-\x7e]*) HTTP/1\.[01]$') { Send-Text $ctx 400 'Bad request' $null; return }
    $method = $Matches[1]; $target = $Matches[2]
    $ctx.Method = $method

    $hdr = @{}
    if ($lines.Count - 1 -gt $MaxHeaderCount) { Send-Text $ctx 431 'Too many headers' $null; return }
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        $c = $ln.IndexOf(':')
        if ($c -le 0) { Send-Text $ctx 400 'Bad header' $null; return }
        $k = $ln.Substring(0, $c).Trim().ToLowerInvariant()
        $v = $ln.Substring($c + 1).Trim()
        if ($k -eq 'host' -and $hdr.ContainsKey('host')) { Send-Text $ctx 400 'Duplicate Host' $null; return }
        $hdr[$k] = $v
    }

    # split target into path + query; never log the token
    $q = $target.IndexOf('?')
    if ($q -ge 0) { $path = $target.Substring(0, $q); $query = $target.Substring($q + 1) } else { $path = $target; $query = '' }
    $ctx.LogPath = ($path -replace '^/(t|T)/[^/]*', '/t/***')
    if ($ctx.LogPath.Length -gt 120) { $ctx.LogPath = $ctx.LogPath.Substring(0, 120) + '...' }

    if ($method -ne 'GET' -and $method -ne 'HEAD') {
        Send-Text $ctx 405 'Read-only server: only GET and HEAD are allowed.' @{ 'Allow' = 'GET, HEAD' }; return
    }
    $ctx.Head = ($method -eq 'HEAD')
    if ($hdr.ContainsKey('transfer-encoding') -or ($hdr.ContainsKey('content-length') -and $hdr['content-length'] -ne '0')) {
        Send-Text $ctx 413 'Request bodies are not accepted' $null; return
    }
    if (-not (Test-HostHeader $hdr['host'])) { Send-Text $ctx 421 'Unknown Host header (use the IP address, or add the name with -AllowHost).' $null; return }

    # ---- access token: /t/TOKEN (QR-friendly) or ?t=TOKEN sets a cookie, then redirects
    # to '/' (never to the request path: '//host/' would be an open redirect).
    $linkToken = $null
    if ($path -match '^/[tT]/([A-Za-z0-9]{1,64})/?$') { $linkToken = $Matches[1] }
    else { $qt = Get-QueryValue $query 't'; if ($qt) { $linkToken = $qt } }
    if ($null -ne $linkToken) {
        if ($AccessToken -and -not (Test-TokenEqual $linkToken $AccessToken)) {
            Send-Text $ctx 403 'Wrong or old access link. Use the link printed in the server window.' $null; return
        }
        $h = @{ 'Location' = '/' }
        if ($AccessToken) { $h['Set-Cookie'] = "$CookieName=$AccessToken; Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax" }
        Send-Text $ctx 302 'Redirecting' $h; return
    }
    if ($AccessToken -and -not $isLocalClient) {
        if (-not (Test-TokenEqual (Get-Cookie $hdr['cookie'] $CookieName) $AccessToken)) {
            Send-Text $ctx 401 'Access link required: open the /t/... link (or scan its QR code) printed in the server window on the gaming PC.' $null; return
        }
    }

    # ---- file
    $res = Resolve-RequestPath $path
    # Plugins replace the data file with delete+rename (Lua os.rename cannot overwrite on Windows),
    # so a file can be missing for a few ms. Wait briefly before answering 404.
    for ($w = 0; $w -lt 5 -and $res.Kind -eq 'missing'; $w++) { Start-Sleep -Milliseconds 40; $res = Resolve-RequestPath $path }
    switch ($res.Kind) {
        'dir'     { Send-Text $ctx 301 'Moved' @{ 'Location' = ($path + '/') }; return }
        'none'    { Send-Text $ctx 404 'Not found' $null; return }
        'missing' { Send-Text $ctx 404 'Not found' $null; return }
    }

    $bytes = $null
    for ($attempt = 0; $attempt -lt 6 -and $null -eq $bytes; $attempt++) {
        # The plugins rewrite the data file every few seconds: share everything, retry briefly.
        try {
            $fs = [IO.File]::Open($res.Full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
            try {
                if ($fs.Length -gt $MaxFileBytes) { Send-Text $ctx 403 'File too large' $null; return }
                $len = [int]$fs.Length
                $buf = New-Object byte[] $len
                $got = 0
                while ($got -lt $len) { $r = $fs.Read($buf, $got, $len - $got); if ($r -le 0) { break }; $got += $r }
                if ($got -eq $len) { $bytes = $buf }
            } finally { $fs.Dispose() }
        } catch [UnauthorizedAccessException] {
            Send-Text $ctx 403 'Forbidden' $null; return
        } catch [IO.IOException] {
            Start-Sleep -Milliseconds 40      # locked, or mid delete+rename
        }
    }
    if ($null -eq $bytes -or ($bytes.Length -eq 0 -and -not $Cacheable.ContainsKey($res.Ext))) {
        Send-Text $ctx 503 'File busy (being rewritten), retry' @{ 'Retry-After' = '1' }; return
    }
    $cache = if ($Cacheable.ContainsKey($res.Ext)) { 'public, max-age=300' } else { 'no-store, max-age=0' }
    Send-Response $ctx 200 @{ 'Content-Type' = $Mime[$res.Ext]; 'Cache-Control' = $cache; 'Pragma' = 'no-cache' } $bytes
}

# ---------------------------------------------------------------- startup banner
function Get-LocalIPv4 {
    $out = @()
    foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up') { continue }
        if ($nic.NetworkInterfaceType -eq 'Loopback') { continue }
        foreach ($ua in $nic.GetIPProperties().UnicastAddresses) {
            $a = $ua.Address
            if ($a.AddressFamily -ne 'InterNetwork') { continue }
            if ($a.ToString().StartsWith('169.254.')) { continue }
            $out += [pscustomobject]@{ Ip = $a.ToString(); Name = $nic.Name }
        }
    }
    $out
}

$listener = New-Object Net.Sockets.TcpListener($bindIp, $Port)
if ($IsWin) { $listener.ExclusiveAddressUse = $true }   # no other process can co-bind/hijack the port
try {
    $listener.Start(32)
} catch [Net.Sockets.SocketException] {
    $se = $_.Exception
    Write-Host "Could not listen on port $Port ($($se.SocketErrorCode))." -ForegroundColor Red
    if ($se.SocketErrorCode -eq 'AddressAlreadyInUse') { Write-Host 'Another program (or another copy of this server) is using it. Close it or use -Port 8766.' }
    if ($se.SocketErrorCode -eq 'AccessDenied') { Write-Host 'Windows reserves this port (often Hyper-V/WSL/Docker). Check: netsh int ipv4 show excludedportrange protocol=tcp  -- then pick another -Port.' }
    exit 3
}

if (Test-Path -LiteralPath $StopFile) { Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue }
try { $Host.UI.RawUI.WindowTitle = "WarRoom dashboard server :$Port" } catch { }

Write-Host ''
Write-Host "Serving (read-only): $RootFull"
if (-not $RemoteMode) {
    Write-Host "Mode: THIS PC ONLY. Open:  http://127.0.0.1:$Port/" -ForegroundColor Green
    Write-Host 'For phones/tablets on your Wi-Fi run serve-lan.bat (or serve.bat -Lan).'
} else {
    $suffix = ''
    if ($AccessToken) { $suffix = "t/$AccessToken" }
    Write-Host 'Mode: HOME NETWORK. On this PC:' -ForegroundColor Yellow
    Write-Host "   http://127.0.0.1:$Port/"
    Write-Host 'From a phone/tablet/other PC use one of:' -ForegroundColor Yellow
    $ips = @(Get-LocalIPv4)
    if ($bindIp -ne [Net.IPAddress]::Any) { $ips = @($ips | Where-Object { $_.Ip -eq $bindIp.ToString() }) }
    foreach ($e in $ips) {
        Write-Host ("   http://{0}:{1}/{2}    ({3})" -f $e.Ip, $Port, $suffix, $e.Name) -ForegroundColor Green
    }
    if ($ips.Count -gt 0) {
        Write-Host 'QR-friendly (all caps = smaller QR code; paste into any QR generator):'
        Write-Host ("   HTTP://{0}:{1}/{2}" -f $ips[0].Ip, $Port, $suffix.ToUpperInvariant())
    }
    if ($AccessToken) {
        Write-Host 'The link contains a private key. Share it only with your own devices.' -ForegroundColor Yellow
        Write-Host 'After opening it once, the device remembers it (cookie). Rotate with -NewToken.'
    } else {
        Write-Host 'WARNING: -NoToken: anyone on this network can read the dashboard.' -ForegroundColor Red
    }
    Write-Host ''
    Write-Host 'If Windows asks about the firewall: tick ONLY "Private networks" and click Allow.'
    Write-Host 'Your Wi-Fi must be set to "Private" in Windows settings, or other devices cannot connect.'
    Write-Host "Narrow alternative (admin PowerShell, once):"
    Write-Host "   New-NetFirewallRule -DisplayName 'QQT WarRoom' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Private -RemoteAddress LocalSubnet"
}
Write-Host 'Stop: Ctrl+C or close this window. (Do not click inside the window: selecting text pauses the server until you press Esc.)'
Write-Host ''

# ---------------------------------------------------------------- main loop
$stopCheck = [Diagnostics.Stopwatch]::StartNew()
try {
    while ($true) {
        if ($stopCheck.ElapsedMilliseconds -ge 1000) {
            $stopCheck.Restart()
            if (Test-Path -LiteralPath $StopFile) { Write-Log 'stop.flag found, shutting down'; Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue; break }
        }
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 25; continue }   # keeps Ctrl+C responsive
        $client = $listener.AcceptTcpClient()
        try {
            Invoke-Client $client
        } catch {
            Write-Log "error: $($_.Exception.Message)"
        } finally {
            try { $client.Client.Shutdown([Net.Sockets.SocketShutdown]::Send) } catch { }
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
    Write-Host 'Server stopped.'
}
exit 0

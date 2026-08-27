#Requires -Version 5.1
# ============================================================================
#  Agent CLI Command Palette  --  a dockable sidebar for any Windows terminal
#
#  The palette itself understands nothing about the commands it sends: it types
#  an item's text into the terminal you bound, or sends its key combo. Point it
#  at a different commands.json (-Config) and it drives claude, gemini, codex,
#  kubectl or anything else without a code change.
#
#  NOTE ON ENCODING: this file is intentionally ASCII-only. Windows PowerShell
#  5.1 decodes BOM-less .ps1 files with the system ANSI codepage, which would
#  turn embedded Chinese into mojibake. All user-visible text therefore lives
#  in commands.json, which is read explicitly as UTF-8.
# ============================================================================
[CmdletBinding()]
param(
    [string]$Config,
    # Builds the whole UI and runs internal checks without showing the window.
    [switch]$SelfTest,
    # With -SelfTest: also spawn a real terminal and round-trip a command
    # through it, so the SendInput / clipboard paths are proven end to end.
    [switch]$Live,
    # Leave powershell.exe's own console window on screen. Only useful for
    # troubleshooting; normally the console is hidden once the palette is up.
    [switch]$KeepConsole
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ---------------------------------------------------------------------------
# Win32 interop: window discovery / placement / synthetic keyboard input
# ---------------------------------------------------------------------------
if (-not ('Nx' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class Nx
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint procId);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFO mi);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();

    // The palette is a GUI; the console window exists only because
    // powershell.exe is a console-subsystem host. Drop it from the screen and
    // the taskbar. Called after the UI is built, so startup errors still land
    // in a console the user can read.
    public static bool HideOwnConsole()
    {
        IntPtr h = GetConsoleWindow();
        if (h == IntPtr.Zero) return false;
        return ShowWindow(h, 0); // SW_HIDE
    }

    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();

    // SendInput goes to whatever window owns the keyboard focus, so activating
    // the target is not cosmetic -- if it fails the command would be typed into
    // the palette's own search box. A bare SetForegroundWindow is unreliable
    // for a window belonging to another process; attaching our input queue to
    // the target's thread lifts that restriction. The return value is the
    // verified outcome, never a hopeful "we asked for it".
    public static bool FocusWindow(IntPtr h)
    {
        if (h == IntPtr.Zero || !IsWindow(h)) return false;
        if (IsIconic(h)) ShowWindow(h, 9); // SW_RESTORE
        if (GetForegroundWindow() == h) return true;

        uint procId;
        uint target = GetWindowThreadProcessId(h, out procId);
        uint mine = GetCurrentThreadId();
        bool attached = (target != mine) && AttachThreadInput(mine, target, true);
        try
        {
            for (int i = 0; i < 12; i++)
            {
                SetForegroundWindow(h);
                BringWindowToTop(h);
                if (GetForegroundWindow() == h) return true;
                System.Threading.Thread.Sleep(25);
            }
        }
        finally { if (attached) AttachThreadInput(mine, target, false); }
        return GetForegroundWindow() == h;
    }

    delegate bool EnumProc(IntPtr h, IntPtr p);

    public static string GetClass(IntPtr h)
    {
        StringBuilder sb = new StringBuilder(256);
        GetClassName(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string GetTitle(IntPtr h)
    {
        StringBuilder sb = new StringBuilder(1024);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static IntPtr[] VisibleWindows()
    {
        List<IntPtr> list = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr p) { if (IsWindowVisible(h)) list.Add(h); return true; }, IntPtr.Zero);
        return list.ToArray();
    }

    // Work area (screen minus taskbar) of the monitor holding the given window.
    public static RECT WorkArea(IntPtr h)
    {
        IntPtr mon = MonitorFromWindow(h, 2); // MONITOR_DEFAULTTONEAREST
        MONITORINFO mi = new MONITORINFO();
        mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        GetMonitorInfo(mon, ref mi);
        return mi.rcWork;
    }
    // ---------------- clipboard (native) ----------------
    // System.Windows.Clipboard throws CLIPBRD_E_CANT_OPEN whenever any other
    // process holds the clipboard open -- clipboard managers and IMEs do this
    // constantly. Going through the Win32 API lets us retry properly.

    [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern bool EmptyClipboard();
    [DllImport("user32.dll")] static extern IntPtr SetClipboardData(uint fmt, IntPtr mem);
    [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint fmt);
    [DllImport("user32.dll")] static extern bool IsClipboardFormatAvailable(uint fmt);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr mem);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr mem);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr mem);

    const uint CF_UNICODETEXT = 13;
    const uint GMEM_MOVEABLE = 0x0002;

    public static bool SetClipboardText(string s)
    {
        if (s == null) return false;
        for (int attempt = 0; attempt < 25; attempt++)
        {
            if (OpenClipboard(IntPtr.Zero))
            {
                try
                {
                    EmptyClipboard();
                    IntPtr mem = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)((s.Length + 1) * 2));
                    if (mem == IntPtr.Zero) return false;
                    IntPtr p = GlobalLock(mem);
                    if (p == IntPtr.Zero) { GlobalFree(mem); return false; }
                    try
                    {
                        Marshal.Copy(s.ToCharArray(), 0, p, s.Length);
                        Marshal.WriteInt16(p, s.Length * 2, 0);
                    }
                    finally { GlobalUnlock(mem); }
                    // On success the clipboard owns the block; do not free it.
                    if (SetClipboardData(CF_UNICODETEXT, mem) == IntPtr.Zero) { GlobalFree(mem); return false; }
                    return true;
                }
                finally { CloseClipboard(); }
            }
            System.Threading.Thread.Sleep(40);
        }
        return false;
    }
    public static string GetClipboardText()
    {
        for (int attempt = 0; attempt < 25; attempt++)
        {
            if (OpenClipboard(IntPtr.Zero))
            {
                try
                {
                    if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) return null;
                    IntPtr h = GetClipboardData(CF_UNICODETEXT);
                    if (h == IntPtr.Zero) return null;
                    IntPtr p = GlobalLock(h);
                    if (p == IntPtr.Zero) return null;
                    try { return Marshal.PtrToStringUni(p); }
                    finally { GlobalUnlock(h); }
                }
                finally { CloseClipboard(); }
            }
            System.Threading.Thread.Sleep(40);
        }
        return null;
    }
    // ---------------- synthetic keyboard input (SendInput) ----------------

    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }

    [StructLayout(LayoutKind.Explicit)]
    struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public INPUTUNION u; }

    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint n, INPUT[] inputs, int size);

    const uint EXTENDED = 0x0001;
    const uint KEYUP    = 0x0002;
    const uint UNICODE  = 0x0004;

    // Keys that live on the "extended" part of the keyboard need the flag,
    // otherwise consoles see the numpad twin instead (e.g. Up vs numpad-8).
    static bool IsExtended(ushort vk)
    {
        switch (vk)
        {
            case 0x21: case 0x22: case 0x23: case 0x24:   // PgUp PgDn End Home
            case 0x25: case 0x26: case 0x27: case 0x28:   // arrows
            case 0x2D: case 0x2E: case 0x90:              // Ins Del NumLock
                return true;
        }
        return false;
    }

    static INPUT MakeKey(ushort vk, ushort scan, uint flags)
    {
        INPUT i = new INPUT();
        i.type = 1; // INPUT_KEYBOARD
        i.u.ki.wVk = vk;
        i.u.ki.wScan = scan;
        i.u.ki.dwFlags = flags;
        i.u.ki.time = 0;
        i.u.ki.dwExtraInfo = IntPtr.Zero;
        return i;
    }
    // Press every key in order, then release in reverse -- a real chord.
    public static void SendCombo(ushort[] vks)
    {
        if (vks == null || vks.Length == 0) return;
        List<INPUT> l = new List<INPUT>();
        for (int i = 0; i < vks.Length; i++)
        {
            uint f = IsExtended(vks[i]) ? EXTENDED : 0;
            l.Add(MakeKey(vks[i], (ushort)MapVirtualKey(vks[i], 0), f));
        }
        for (int i = vks.Length - 1; i >= 0; i--)
        {
            uint f = KEYUP | (IsExtended(vks[i]) ? EXTENDED : 0);
            l.Add(MakeKey(vks[i], (ushort)MapVirtualKey(vks[i], 0), f));
        }
        INPUT[] a = l.ToArray();
        SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
    }

    // Type a literal string as Unicode key events -- no clipboard involved.
    public static void SendText(string s)
    {
        if (string.IsNullOrEmpty(s)) return;
        List<INPUT> l = new List<INPUT>();
        ushort enterScan = (ushort)MapVirtualKey(0x0D, 0);
        foreach (char c in s)
        {
            if (c == '\r') continue;
            if (c == '\n')
            {
                l.Add(MakeKey(0x0D, enterScan, 0));
                l.Add(MakeKey(0x0D, enterScan, KEYUP));
                continue;
            }
            l.Add(MakeKey(0, (ushort)c, UNICODE));
            l.Add(MakeKey(0, (ushort)c, UNICODE | KEYUP));
        }
        if (l.Count == 0) return;
        INPUT[] a = l.ToArray();
        SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$Root = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }

# One CLI per file: commands-claude.json, commands-codex.json, ... The suffix is
# the profile name shown in the switcher, so supporting another CLI means
# dropping a file in beside the script -- no code change and no restart.
function Get-Profiles {
    $found = New-Object System.Collections.Generic.List[object]
    $files = @(Get-ChildItem -LiteralPath $Root -Filter 'commands-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object Name)
    foreach ($f in $files) {
        $found.Add([pscustomobject]@{
                Name = $f.BaseName.Substring('commands-'.Length)
                Path = $f.FullName
            })
    }
    # A single unsuffixed commands.json still works, so an older setup keeps running.
    $plain = Join-Path $Root 'commands.json'
    if (Test-Path -LiteralPath $plain) {
        $found.Add([pscustomobject]@{ Name = 'default'; Path = $plain })
    }
    # Emitted as loose objects, not as one array object: callers wrap in @() and
    # index into it, and the `, $x` idiom made $known[0] the whole array here.
    return $found.ToArray()
}

function Get-ProfileName {
    param([string]$Path)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if ($base -like 'commands-*') { return $base.Substring('commands-'.Length) }
    return $base
}

if ([string]::IsNullOrWhiteSpace($Config)) {
    $known = @(Get-Profiles)
    $Config = if ($known.Count -gt 0) { $known[0].Path } else { Join-Path $Root 'commands.json' }
}
$script:ProfileName = Get-ProfileName $Config
function Read-Config {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "commands.json not found: $Path" }
    # ReadAllText detects the BOM and falls back to UTF-8, which is what the
    # command table is written in. Get-Content would use the ANSI codepage.
    return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}

try {
    $script:Cfg = Read-Config -Path $Config
}
catch {
    # ui.title lives in the config that just failed to load, so this one caption
    # has to be hardcoded. It is the only place the tool names itself in code.
    [void][System.Windows.MessageBox]::Show("$($_.Exception.Message)", 'Agent CLI Palette',
        [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    return
}

$script:UI = $script:Cfg.ui
$script:Opt = $script:Cfg.settings
$script:Target = [IntPtr]::Zero

# Window classes that identify a console host we can drive.
$script:TermClasses = @(
    'ConsoleWindowClass',                  # conhost (classic powershell.exe / cmd.exe)
    'CASCADIA_HOSTING_WINDOW_CLASS',       # Windows Terminal
    'VirtualConsoleClass',                 # ConEmu / Cmder
    'mintty',                              # Git Bash
    'VirtualConsoleClass2'                 # ConEmu variants
)
# Only these are trusted when auto-detecting a terminal we just spawned;
# Chrome_WidgetWin_1 and friends are far too generic for that job.
$script:SpawnClasses = @('CASCADIA_HOSTING_WINDOW_CLASS', 'ConsoleWindowClass')
$script:TermProcs = @(
    'WindowsTerminal', 'powershell', 'pwsh', 'cmd', 'conhost', 'ConEmu64',
    'ConEmu', 'mintty', 'wezterm-gui', 'alacritty', 'Hyper', 'Code'
)

# ---------------------------------------------------------------------------
# Virtual-key parsing: "Ctrl+Shift+P" -> ushort[]
# ---------------------------------------------------------------------------
$script:VkNames = @{
    'ctrl' = 0x11; 'control' = 0x11; 'shift' = 0x10; 'alt' = 0x12; 'menu' = 0x12
    'win' = 0x5B; 'lwin' = 0x5B; 'rwin' = 0x5C
    'enter' = 0x0D; 'return' = 0x0D; 'tab' = 0x09; 'esc' = 0x1B; 'escape' = 0x1B
    'space' = 0x20; 'back' = 0x08; 'backspace' = 0x08; 'bs' = 0x08
    'del' = 0x2E; 'delete' = 0x2E; 'ins' = 0x2D; 'insert' = 0x2D
    'home' = 0x24; 'end' = 0x23; 'pgup' = 0x21; 'pageup' = 0x21
    'pgdn' = 0x22; 'pagedown' = 0x22
    'up' = 0x26; 'down' = 0x28; 'left' = 0x25; 'right' = 0x27
}
1..12 | ForEach-Object { $script:VkNames["f$_"] = 0x6F + $_ }
function ConvertTo-VkCombo {
    param([string]$Combo)
    $vks = New-Object System.Collections.Generic.List[uint16]
    foreach ($part in ($Combo -split '\+')) {
        $p = $part.Trim()
        if ($p.Length -eq 0) { continue }
        $key = $p.ToLowerInvariant()
        if ($script:VkNames.ContainsKey($key)) {
            $vks.Add([uint16]$script:VkNames[$key])
        }
        elseif ($p.Length -eq 1) {
            $ch = ([string]$p).ToUpperInvariant()[0]
            $vks.Add([uint16][int]$ch)
        }
        else {
            Write-Verbose "Unknown key name: $p"
        }
    }
    return , $vks.ToArray()
}

# WPF equivalent of DoEvents -- keeps the sidebar painting during short waits.
function Invoke-Pump {
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [System.Windows.Threading.DispatcherOperationCallback] { param($f) $f.Continue = $false; return $null },
        $frame)
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Start-Wait {
    param([int]$Ms)
    $end = [datetime]::UtcNow.AddMilliseconds($Ms)
    while ([datetime]::UtcNow -lt $end) {
        Invoke-Pump
        Start-Sleep -Milliseconds 15
    }
}

# The clipboard is a shared, lock-prone resource; the native helpers already
# retry for about a second before giving up.
function Set-ClipText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return [Nx]::SetClipboardText($Text)
}

function Get-ClipText {
    return [Nx]::GetClipboardText()
}

# ---------------------------------------------------------------------------
# Target terminal window
# ---------------------------------------------------------------------------
function Test-Target {
    if ($script:Target -eq [IntPtr]::Zero) { return $false }
    if (-not [Nx]::IsWindow($script:Target)) {
        $script:Target = [IntPtr]::Zero
        Update-Status
        return $false
    }
    return $true
}

function Set-Target {
    param([IntPtr]$Handle)
    $script:Target = $Handle
    Update-Status
}

function Show-Warn {
    param([string]$Text)
    [void][System.Windows.MessageBox]::Show($Text, $script:UI.title,
        [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
}

function Enable-TargetFocus {
    return [Nx]::FocusWindow($script:Target)
}

function Get-WindowCandidates {
    $self = (New-Object System.Windows.Interop.WindowInteropHelper($script:Win)).Handle
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($h in [Nx]::VisibleWindows()) {
        if ($h -eq $self) { continue }
        $title = [Nx]::GetTitle($h)
        if ([string]::IsNullOrWhiteSpace($title)) { continue }
        $cls = [Nx]::GetClass($h)
        $procId = 0
        [void][Nx]::GetWindowThreadProcessId($h, [ref]$procId)
        $pname = ''
        try { $pname = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { }
        $isTerm = ($script:TermClasses -contains $cls) -or ($script:TermProcs -contains $pname)
        $tag = if ($isTerm) { $script:UI.pickTerminalTag } else { '' }
        $list.Add([pscustomobject]@{
                Hwnd    = $h
                IsTerm  = $isTerm
                Display = "$tag[$pname] $title"
            })
    }
    return @($list | Sort-Object -Property @{ Expression = { -[int]$_.IsTerm } }, Display)
}
function Show-TargetPicker {
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="Manual" Width="660" Height="480"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        Background="#FF1B1B1F" Foreground="#FFE8E8EA">
  <DockPanel Margin="12">
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="Ok" Width="96" Height="28" Margin="0,0,8,0"/>
      <Button x:Name="Cancel" Width="96" Height="28" IsCancel="True"/>
    </StackPanel>
    <ListBox x:Name="List" Background="#FF232329" Foreground="#FFE8E8EA"
             BorderBrush="#FF3A3A44" FontSize="12"/>
  </DockPanel>
</Window>
'@
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Title = $script:UI.pickTitle
    $dlg.Owner = $script:Win
    $lb = $dlg.FindName('List')
    $ok = $dlg.FindName('Ok')
    $cancel = $dlg.FindName('Cancel')
    $ok.Content = $script:UI.pickOk
    $cancel.Content = $script:UI.pickCancel

    $items = Get-WindowCandidates
    $lb.ItemsSource = $items
    $lb.DisplayMemberPath = 'Display'
    if ($items.Count -gt 0) { $lb.SelectedIndex = 0 }

    # The picked handle rides on $dlg.Tag rather than a $script: variable:
    # GetNewClosure() hosts the handler in its own dynamic module, so a
    # "$script:" assignment inside it lands in that module and never reaches
    # this function -- which silently broke binding entirely.
    $dlg.Tag = $null
    $accept = {
        if ($null -ne $lb.SelectedItem) {
            $dlg.Tag = $lb.SelectedItem.Hwnd
            $dlg.DialogResult = $true
        }
    }.GetNewClosure()
    $ok.Add_Click($accept)
    $lb.Add_MouseDoubleClick($accept)
    $cancel.Add_Click({ $dlg.DialogResult = $false }.GetNewClosure())

    [void]$dlg.ShowDialog()
    if ($null -eq $dlg.Tag) { return [IntPtr]::Zero }
    return [IntPtr]$dlg.Tag
}
function Get-ShellExe {
    $want = [string]$script:Opt.shell
    if ($want -and $want -ne 'auto') {
        $c = Get-Command $want -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    $c = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return (Get-Command powershell.exe).Source
}

function New-Terminal {
    $work = [string]$script:Opt.workDir
    if ([string]::IsNullOrWhiteSpace($work) -or -not (Test-Path -LiteralPath $work)) {
        $work = $script:Root
    }
    $work = $work.TrimEnd('\')

    # Snapshot existing top-level windows so we can spot the new one.
    $before = @{}
    foreach ($h in [Nx]::VisibleWindows()) { $before[[int64]$h] = $true }

    $shell = Get-ShellExe
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    try {
        if ($wt) {
            # -w -1 forces a brand new Windows Terminal window rather than a tab
            # in an existing one. Quote the path ourselves: Start-Process joins
            # ArgumentList with spaces and adds no quoting of its own.
            $wtArgs = @('-w', '-1', '-d', ('"{0}"' -f $work), ('"{0}"' -f $shell), '-NoLogo', '-NoExit')
            Start-Process -FilePath $wt.Source -ArgumentList $wtArgs | Out-Null
        }
        else {
            Start-Process -FilePath $shell -ArgumentList @('-NoLogo', '-NoExit') -WorkingDirectory $work | Out-Null
        }
    }
    catch {
        Show-Warn $_.Exception.Message
        return [IntPtr]::Zero
    }

    $deadline = [datetime]::UtcNow.AddSeconds(10)
    while ([datetime]::UtcNow -lt $deadline) {
        Start-Wait 200
        foreach ($h in [Nx]::VisibleWindows()) {
            if ($before.ContainsKey([int64]$h)) { continue }
            if ($script:SpawnClasses -contains [Nx]::GetClass($h)) { return $h }
        }
    }
    return [IntPtr]::Zero
}
# ---------------------------------------------------------------------------
# Layout: sidebar pinned left, terminal resized to fill the rest
# ---------------------------------------------------------------------------
function Set-DockLayout {
    if (-not (Test-Target)) { Show-Warn $script:UI.errNoTarget; return }
    if ([Nx]::IsIconic($script:Target)) { [void][Nx]::ShowWindow($script:Target, 9) }

    $src = [System.Windows.Interop.HwndSource]::FromVisual($script:Win)
    if ($null -eq $src) { return }
    $toDip = $src.CompositionTarget.TransformFromDevice
    $toPx = $src.CompositionTarget.TransformToDevice

    $wa = [Nx]::WorkArea($script:Target)
    $sideW = [int][math]::Round($script:Win.ActualWidth * $toPx.M11)
    if ($sideW -le 0) { $sideW = 300 }

    # Sidebar first (WPF coordinates are device-independent pixels).
    $tl = $toDip.Transform((New-Object System.Windows.Point($wa.Left, $wa.Top)))
    $script:Win.Left = $tl.X
    $script:Win.Top = $tl.Y
    $script:Win.Height = ($wa.Bottom - $wa.Top) * $toDip.M22

    # Then the terminal, in raw pixels, without stealing focus or z-order.
    $x = $wa.Left + $sideW
    $w = $wa.Right - $x
    $h = $wa.Bottom - $wa.Top
    if ($w -gt 200) {
        [void][Nx]::SetWindowPos($script:Target, [IntPtr]::Zero, $x, $wa.Top, $w, $h, 0x0014)
    }
}

# ---------------------------------------------------------------------------
# Sending a palette entry to the terminal
# ---------------------------------------------------------------------------
function Invoke-PaletteItem {
    param([object]$Item)

    if (-not (Test-Target)) {
        Show-Warn $script:UI.errNoTarget
        return
    }

    $keys = $Item.keys
    $text = [string]$Item.cmd
    if (-not $keys -and [string]::IsNullOrEmpty($text)) { return }

    # Stage the clipboard before stealing focus so the Ctrl+V lands fast.
    $usePaste = (-not $keys) -and (-not [bool]$script:ChkType.IsChecked)
    $saved = $null
    $staged = $false
    if ($usePaste) {
        $saved = Get-ClipText
        $staged = Set-ClipText $text
    }

    # Bail out rather than type the command into our own search box.
    if (-not (Enable-TargetFocus)) {
        Show-Warn ([string]$script:UI.errFocus)
        return
    }

    if ($keys) {
        foreach ($combo in $keys) {
            [Nx]::SendCombo((ConvertTo-VkCombo $combo))
            Start-Sleep -Milliseconds 60
        }
        return
    }

    if ($staged) {
        [Nx]::SendCombo([uint16[]]@(0x11, 0x56))   # Ctrl+V
        Start-Wait 180
        if (-not [string]::IsNullOrEmpty($saved)) { [void](Set-ClipText $saved) }
    }
    else {
        [Nx]::SendText($text)
    }

    if ([bool]$script:ChkEnter.IsChecked) {
        Start-Sleep -Milliseconds 80
        [Nx]::SendCombo([uint16[]]@(0x0D))
    }
}

function Copy-PaletteItem {
    param([object]$Item)
    $text = if ($Item.keys) { ($Item.keys -join ' , ') } else { [string]$Item.cmd }
    if (-not [string]::IsNullOrEmpty($text)) { [void](Set-ClipText $text) }
}
# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------
$MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="300" Height="840" MinWidth="230" MinHeight="320"
        WindowStartupLocation="Manual" ShowInTaskbar="True"
        Background="#FF17171B" Foreground="#FFE9E9EC"
        FontFamily="Microsoft YaHei UI, Segoe UI" FontSize="12">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#FFD97757"/>
    <SolidColorBrush x:Key="Muted"  Color="#FF8E8E9A"/>
    <SolidColorBrush x:Key="Panel"  Color="#FF202027"/>
    <SolidColorBrush x:Key="Field"  Color="#FF121216"/>
    <SolidColorBrush x:Key="Line"   Color="#FF34343E"/>

    <Style x:Key="CmdBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#FFE9E9EC"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="9,6,6,6"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="4"
                    BorderThickness="3,0,0,0" BorderBrush="Transparent" SnapsToDevicePixels="True">
              <ContentPresenter Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FF2C2C35"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#FFD97757"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FF3C3C48"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ToolBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#FFE9E9EC"/>
      <Setter Property="Background" Value="#FF2C2C35"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FFD97757"/>
                <Setter Property="Foreground" Value="#FF17171B"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="LinkBtn" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <TextBlock Text="{TemplateBinding Content}" Foreground="{TemplateBinding Foreground}"
                       TextDecorations="Underline" Margin="6,0,0,0"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Chk" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="0,2,0,2"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style x:Key="Search" TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Field}"/>
      <Setter Property="Foreground" Value="#FFE9E9EC"/>
      <Setter Property="CaretBrush" Value="#FFD97757"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="Height" Value="26"/>
    </Style>

    <Style x:Key="GroupExp" TargetType="Expander">
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Margin" Value="0,2,0,6"/>
      <Setter Property="IsExpanded" Value="True"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="11"/>
    </Style>
  </Window.Resources>

  <DockPanel LastChildFill="True">
    <Border DockPanel.Dock="Top" Background="{StaticResource Panel}" Padding="10,10,10,10">
      <StackPanel>
        <TextBlock x:Name="TitleText" FontSize="14" FontWeight="Bold"/>
        <TextBlock x:Name="StatusText" FontSize="11" Foreground="{StaticResource Muted}"
                   TextTrimming="CharacterEllipsis" Margin="0,4,0,0"/>
        <UniformGrid Columns="3" Margin="0,9,0,0">
          <Button x:Name="BtnNew"  Style="{StaticResource ToolBtn}" Margin="0,0,3,0"/>
          <Button x:Name="BtnBind" Style="{StaticResource ToolBtn}" Margin="3,0,3,0"/>
          <Button x:Name="BtnDock" Style="{StaticResource ToolBtn}" Margin="3,0,0,0"/>
        </UniformGrid>
        <Button x:Name="BtnProfile" Style="{StaticResource ToolBtn}" Margin="0,6,0,0"/>
        <TextBlock x:Name="SearchHint" FontSize="10" Foreground="{StaticResource Muted}" Margin="1,9,0,3"/>
        <TextBox x:Name="SearchBox" Style="{StaticResource Search}"/>
        <StackPanel Margin="0,7,0,0">
          <CheckBox x:Name="ChkEnter" Style="{StaticResource Chk}"/>
          <CheckBox x:Name="ChkTop"   Style="{StaticResource Chk}"/>
          <CheckBox x:Name="ChkType"  Style="{StaticResource Chk}"/>
        </StackPanel>
      </StackPanel>
    </Border>
    <Border DockPanel.Dock="Bottom" Background="{StaticResource Panel}" Padding="10,6,10,7">
      <DockPanel>
        <Button x:Name="BtnReload" DockPanel.Dock="Right" Style="{StaticResource LinkBtn}"/>
        <TextBlock x:Name="HintText" FontSize="10" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
      </DockPanel>
    </Border>
    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="6,8,6,8">
      <StackPanel x:Name="ListHost"/>
    </ScrollViewer>
  </DockPanel>
</Window>
'@
$reader = New-Object System.Xml.XmlNodeReader ([xml]$MainXaml)
$script:Win = [System.Windows.Markup.XamlReader]::Load($reader)

foreach ($n in 'TitleText', 'StatusText', 'BtnNew', 'BtnBind', 'BtnDock', 'SearchHint',
    'SearchBox', 'ChkEnter', 'ChkTop', 'ChkType', 'BtnReload', 'HintText', 'ListHost',
    'BtnProfile') {
    Set-Variable -Name $n -Scope Script -Value $script:Win.FindName($n)
}

function Set-UiText {
    $script:Win.Title = [string]$script:UI.title
    $script:TitleText.Text = [string]$script:UI.title
    $script:BtnNew.Content = [string]$script:UI.btnNewTerminal
    $script:BtnBind.Content = [string]$script:UI.btnBind
    $script:BtnDock.Content = [string]$script:UI.btnDock
    $script:SearchHint.Text = [string]$script:UI.searchHint
    $script:ChkEnter.Content = [string]$script:UI.chkAutoEnter
    $script:ChkTop.Content = [string]$script:UI.chkTopMost
    $script:ChkType.Content = [string]$script:UI.chkTypeMode
    $script:BtnReload.Content = [string]$script:UI.reloadBtn
    $script:HintText.Text = [string]$script:UI.tipHelp
    # btnProfile is a format string so the active profile reads as part of the
    # label; a config without the key still gets a usable button.
    $script:BtnProfile.Content = if ([string]::IsNullOrEmpty([string]$script:UI.btnProfile)) {
        $script:ProfileName
    }
    else {
        [string]$script:UI.btnProfile -f $script:ProfileName
    }
}

Set-UiText
$script:ChkEnter.IsChecked = [bool]$script:Opt.autoEnter
$script:ChkTop.IsChecked = [bool]$script:Opt.topMost
$script:ChkType.IsChecked = ([string]$script:Opt.insertMode -ne 'paste')
$script:Win.Topmost = [bool]$script:Opt.topMost
if ([double]$script:Opt.sidebarWidth -gt 180) { $script:Win.Width = [double]$script:Opt.sidebarWidth }

$script:BrushAccent = New-Object System.Windows.Media.SolidColorBrush(
    [System.Windows.Media.Color]::FromRgb(0xD9, 0x77, 0x57))
$script:BrushMuted = New-Object System.Windows.Media.SolidColorBrush(
    [System.Windows.Media.Color]::FromRgb(0x9A, 0x9A, 0xA6))
$script:BrushTipBg = New-Object System.Windows.Media.SolidColorBrush(
    [System.Windows.Media.Color]::FromRgb(0x20, 0x20, 0x27))
$script:BrushTipFg = New-Object System.Windows.Media.SolidColorBrush(
    [System.Windows.Media.Color]::FromRgb(0xE9, 0xE9, 0xEC))
$script:BrushLine = New-Object System.Windows.Media.SolidColorBrush(
    [System.Windows.Media.Color]::FromRgb(0x34, 0x34, 0x3E))

function Update-Status {
    if ($script:Target -ne [IntPtr]::Zero -and [Nx]::IsWindow($script:Target)) {
        $script:StatusText.Text = [string]$script:UI.boundTo + [Nx]::GetTitle($script:Target)
        $script:StatusText.Foreground = $script:BrushAccent
    }
    else {
        $script:StatusText.Text = [string]$script:UI.noTarget
        $script:StatusText.Foreground = $script:BrushMuted
    }
}
function New-ItemToolTip {
    param([object]$Item)

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.MaxWidth = 400

    $head = New-Object System.Windows.Controls.TextBlock
    if ($Item.keys) {
        $head.Text = [string]$script:UI.tipKeys + ($Item.keys -join '  ,  ')
    }
    else {
        $head.Text = [string]$script:UI.tipCmd + [string]$Item.cmd
    }
    $head.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas, Courier New')
    $head.FontWeight = [System.Windows.FontWeights]::Bold
    $head.FontSize = 12.5
    $head.Foreground = $script:BrushAccent
    $head.TextWrapping = [System.Windows.TextWrapping]::Wrap
    [void]$sp.Children.Add($head)

    if ($Item.desc) {
        $d = New-Object System.Windows.Controls.TextBlock
        $d.Text = [string]$Item.desc
        $d.Foreground = $script:BrushTipFg
        $d.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $d.Margin = New-Object System.Windows.Thickness(0, 5, 0, 0)
        [void]$sp.Children.Add($d)
    }

    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = [string]$script:UI.tipHelp
    $h.FontSize = 10
    $h.Foreground = $script:BrushMuted
    $h.Margin = New-Object System.Windows.Thickness(0, 7, 0, 0)
    [void]$sp.Children.Add($h)

    $tt = New-Object System.Windows.Controls.ToolTip
    $tt.Content = $sp
    $tt.Background = $script:BrushTipBg
    $tt.BorderBrush = $script:BrushLine
    $tt.BorderThickness = New-Object System.Windows.Thickness(1)
    $tt.Padding = New-Object System.Windows.Thickness(10, 8, 10, 8)
    $tt.HasDropShadow = $true
    # Placement is also set here, not only via ToolTipService on the owner, so
    # that the tooltip lands in the same spot when it is opened directly.
    $tt.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Right
    $tt.HorizontalOffset = 10
    $tt.VerticalOffset = -6
    return $tt
}
function New-PaletteButton {
    param([object]$Item)

    $b = New-Object System.Windows.Controls.Button
    $b.Style = $script:Win.Resources['CmdBtn']

    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = [string]$Item.label
    $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $tb.FontWeight = [System.Windows.FontWeights]::Normal
    $b.Content = $tb

    $b.Tag = $Item
    $b.ToolTip = New-ItemToolTip $Item
    # Anchor the tooltip to the button's right edge instead of the mouse. With
    # the default mouse-point placement the tooltip lands on top of the next
    # few buttons, so scanning down the list means reading through it. Pinned
    # beside the sidebar it never covers the list, and WPF's popup placement
    # flips it to the left by itself when there is no room on the right.
    [System.Windows.Controls.ToolTipService]::SetPlacement($b, [System.Windows.Controls.Primitives.PlacementMode]::Right)
    [System.Windows.Controls.ToolTipService]::SetPlacementTarget($b, $b)
    [System.Windows.Controls.ToolTipService]::SetHorizontalOffset($b, 10)
    [System.Windows.Controls.ToolTipService]::SetVerticalOffset($b, -6)
    [System.Windows.Controls.ToolTipService]::SetShowDuration($b, 30000)
    [System.Windows.Controls.ToolTipService]::SetInitialShowDelay($b, 350)

    $b.Add_Click({ param($s, $e) Invoke-PaletteItem $s.Tag })
    $b.Add_MouseRightButtonUp({ param($s, $e) Copy-PaletteItem $s.Tag })
    return $b
}

function Test-ItemMatch {
    param([object]$Item, [string]$Filter)
    if ([string]::IsNullOrEmpty($Filter)) { return $true }
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add([string]$Item.label)
    $parts.Add([string]$Item.desc)
    $parts.Add([string]$Item.tags)
    if ($Item.cmd) { $parts.Add([string]$Item.cmd) }
    if ($Item.keys) { $parts.Add(($Item.keys -join ' ')) }
    return ($parts -join ' ').ToLowerInvariant().Contains($Filter)
}

function Update-List {
    param([string]$Filter)

    $f = if ($Filter) { $Filter.Trim().ToLowerInvariant() } else { '' }
    $script:ListHost.Children.Clear()
    $shown = 0

    foreach ($g in $script:Cfg.groups) {
        $hits = @($g.items | Where-Object { Test-ItemMatch $_ $f })
        if ($hits.Count -eq 0) { continue }

        $exp = New-Object System.Windows.Controls.Expander
        $exp.Style = $script:Win.Resources['GroupExp']
        $exp.Header = [string]$g.name
        $inner = New-Object System.Windows.Controls.StackPanel
        $inner.Margin = New-Object System.Windows.Thickness(0, 3, 0, 0)
        foreach ($it in $hits) { [void]$inner.Children.Add((New-PaletteButton $it)) }
        $exp.Content = $inner
        [void]$script:ListHost.Children.Add($exp)
        $shown += $hits.Count
    }
    if ($shown -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = [string]$script:UI.noResult
        $empty.Foreground = $script:BrushMuted
        $empty.Margin = New-Object System.Windows.Thickness(10, 12, 10, 0)
        [void]$script:ListHost.Children.Add($empty)
    }
}

# ---------------------------------------------------------------------------
# Event wiring
# ---------------------------------------------------------------------------
$script:BtnNew.Add_Click({
        $script:BtnNew.IsEnabled = $false
        try {
            $h = New-Terminal
            if ($h -ne [IntPtr]::Zero) {
                Set-Target $h
                Set-DockLayout
            }
            else {
                Show-Warn ([string]$script:UI.errSpawn)
            }
        }
        finally { $script:BtnNew.IsEnabled = $true }
    })

$script:BtnBind.Add_Click({
        $h = Show-TargetPicker
        # IntPtr is a struct, so "if ($h)" would also be true for a cancelled
        # dialog. Compare against Zero explicitly.
        if ($h -ne [IntPtr]::Zero) { Set-Target $h }
    })

$script:BtnDock.Add_Click({ Set-DockLayout })

# Overlay a profile's ui block onto the strings already in use. Each profile file
# normally carries the full block, but a new CLI can get away with just a title
# plus its command table -- anything it omits keeps working instead of rendering
# as blank buttons.
function Merge-UiText {
    param($NewUi)
    if ($null -eq $NewUi) { return $script:UI }
    $merged = @{}
    foreach ($p in $script:UI.PSObject.Properties) { $merged[$p.Name] = $p.Value }
    foreach ($p in $NewUi.PSObject.Properties) { $merged[$p.Name] = $p.Value }
    return [pscustomobject]$merged
}

# Load a different CLI's command table into the running palette. The bound
# terminal is deliberately left alone: switching profiles means "same window,
# different command set".
function Set-Profile {
    param([string]$Path)
    try {
        # Parse before committing, so a broken file leaves the palette usable.
        $cfg = Read-Config -Path $Path
    }
    catch {
        Show-Warn $_.Exception.Message
        return $false
    }
    $script:Config = $Path
    $script:ProfileName = Get-ProfileName $Path
    $script:Cfg = $cfg
    $script:UI = Merge-UiText $cfg.ui
    $script:Opt = $cfg.settings
    Set-UiText
    Update-Status
    Update-List $script:SearchBox.Text
    return $true
}

function New-ProfileMenu {
    $menu = New-Object System.Windows.Controls.ContextMenu
    # Rebuilt on every click, so a .json added while the palette is open shows up.
    foreach ($p in (Get-Profiles)) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $p.Name
        $mi.Tag = $p.Path
        $mi.IsCheckable = $true
        $mi.IsChecked = ($p.Path -eq $script:Config)
        # A plain scriptblock, not GetNewClosure(): a closure would be hosted in
        # its own module and Set-Profile's $script: writes would never escape it.
        $mi.Add_Click({ param($s, $e) [void](Set-Profile ([string]$s.Tag)) })
        [void]$menu.Items.Add($mi)
    }
    $menu.PlacementTarget = $script:BtnProfile
    $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    return $menu
}

function Show-ProfileMenu {
    (New-ProfileMenu).IsOpen = $true
}

$script:BtnProfile.Add_Click({ Show-ProfileMenu })

$script:BtnReload.Add_Click({
        try {
            $script:Cfg = Read-Config -Path $Config
            $script:UI = $script:Cfg.ui
            $script:Opt = $script:Cfg.settings
            Set-UiText
            Update-Status
            Update-List $script:SearchBox.Text
        }
        catch { Show-Warn $_.Exception.Message }
    })

$script:SearchBox.Add_TextChanged({ Update-List $script:SearchBox.Text })

$script:SearchBox.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
            $script:SearchBox.Text = ''
            $e.Handled = $true
        }
    })

$script:ChkTop.Add_Checked({ $script:Win.Topmost = $true })
$script:ChkTop.Add_Unchecked({ $script:Win.Topmost = $false })
$script:Win.Add_Loaded({
        # Park the sidebar against the left edge of its monitor's work area.
        $src = [System.Windows.Interop.HwndSource]::FromVisual($script:Win)
        if ($null -ne $src) {
            $toDip = $src.CompositionTarget.TransformFromDevice
            $self = (New-Object System.Windows.Interop.WindowInteropHelper($script:Win)).Handle
            $wa = [Nx]::WorkArea($self)
            $tl = $toDip.Transform((New-Object System.Windows.Point($wa.Left, $wa.Top)))
            $script:Win.Left = $tl.X
            $script:Win.Top = $tl.Y
            $script:Win.Height = ($wa.Bottom - $wa.Top) * $toDip.M22
        }
        Update-Status
        [void]$script:SearchBox.Focus()
    })

# Notice when the bound terminal disappears, so the status line stays honest.
$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [timespan]::FromMilliseconds(1500)
$script:Timer.Add_Tick({ [void](Test-Target) })
$script:Timer.Start()
$script:Win.Add_Closed({ $script:Timer.Stop() })

Update-List ''

if ($SelfTest) {
    $report = New-Object System.Collections.Generic.List[string]
    $report.Add("config          : $Config")
    $report.Add("profiles        : $(@(Get-Profiles | ForEach-Object { $_.Name }) -join ', ')")
    $report.Add("active profile  : $script:ProfileName")
    $report.Add("groups rendered : $($script:ListHost.Children.Count)")
    $btnCount = 0
    foreach ($exp in $script:ListHost.Children) {
        if ($exp -is [System.Windows.Controls.Expander]) { $btnCount += $exp.Content.Children.Count }
    }
    $report.Add("buttons         : $btnCount")
    # Switching profiles has to swap the whole table and every UI string, then
    # come back cleanly -- a half-applied switch is worse than none.
    $others = @(Get-Profiles | Where-Object { $_.Path -ne $script:Config })
    if ($others.Count -eq 0) {
        $report.Add('profile switch  : skipped (only one profile present)')
    }
    else {
        $back = $script:Config
        $swOk = Set-Profile $others[0].Path
        $swCount = 0
        foreach ($exp in $script:ListHost.Children) {
            if ($exp -is [System.Windows.Controls.Expander]) { $swCount += $exp.Content.Children.Count }
        }
        $report.Add("profile switch  : $script:ProfileName ok=$swOk buttons=$swCount title='$([string]$script:UI.title)'")
        [void](Set-Profile $back)
        $rsCount = 0
        foreach ($exp in $script:ListHost.Children) {
            if ($exp -is [System.Windows.Controls.Expander]) { $rsCount += $exp.Content.Children.Count }
        }
        $report.Add("profile restore : $script:ProfileName buttons=$rsCount same=$($rsCount -eq $btnCount)")
        $report.Add("profile label   : $($script:BtnProfile.Content)")
        # The switcher menu is the only way a user reaches Set-Profile, so build
        # it here too rather than leaving that path untested.
        $menu = New-ProfileMenu
        $checked = @($menu.Items | Where-Object { $_.IsChecked } | ForEach-Object { $_.Header })
        $report.Add("profile menu    : items=$($menu.Items.Count) checked=$($checked -join ',') target=$([bool]$menu.PlacementTarget)")
    }
    $probe = $script:ListHost.Children[0].Content.Children[0]
    $report.Add("tip placement   : $([System.Windows.Controls.ToolTipService]::GetPlacement($probe)) offset=$([System.Windows.Controls.ToolTipService]::GetHorizontalOffset($probe)) target=$([bool]([System.Windows.Controls.ToolTipService]::GetPlacementTarget($probe)))")
    $report.Add("shell           : $(Get-ShellExe)")
    $report.Add("wt.exe          : $([bool](Get-Command wt.exe -ErrorAction SilentlyContinue))")
    $report.Add("Ctrl+V combo    : $((ConvertTo-VkCombo 'Ctrl+V') -join ',')")
    $report.Add("Shift+Tab combo : $((ConvertTo-VkCombo 'Shift+Tab') -join ',')")
    $report.Add("Escape combo    : $((ConvertTo-VkCombo 'Escape') -join ',')")
    $report.Add("F5 combo        : $((ConvertTo-VkCombo 'F5') -join ',')")
    $report.Add("Up combo        : $((ConvertTo-VkCombo 'Up') -join ',')")
    $self = (New-Object System.Windows.Interop.WindowInteropHelper($script:Win)).Handle
    $wa = [Nx]::WorkArea($self)
    $report.Add("work area       : $($wa.Left),$($wa.Top) - $($wa.Right),$($wa.Bottom)")
    $report.Add("visible windows : $(([Nx]::VisibleWindows()).Count)")
    Update-List 'compact'
    $report.Add("filter 'compact': $($script:ListHost.Children.Count) group(s)")
    Update-List 'zzzz-nope'
    $report.Add("filter no-hit   : placeholder=$($script:ListHost.Children[0].Text -eq $script:UI.noResult)")
    Update-List ''
    # Clipboard is only the fallback insert path, but right-click-copy needs it.
    $probe = 'claude --continue'
    $report.Add("clipboard set   : $(Set-ClipText $probe)")
    $got = Get-ClipText
    $report.Add("clipboard get   : $got")
    $report.Add("clipboard match : $($got -eq $probe)")
    $report.Add("insert mode     : $(if ($script:ChkType.IsChecked) { 'type (SendInput)' } else { 'paste (Ctrl+V)' })")
    $report.Add("label decoded   : $(($script:UI.noResult).Length) chars, first=U+$([int][char]($script:UI.noResult)[0])")
    $report.Add("picker candidates: $((Get-WindowCandidates).Count)")

    # Measure the tooltip for real rather than trusting the property: the whole
    # point of anchoring it to the button is that it must land clear of the list.
    $script:Win.ShowInTaskbar = $false
    $script:Win.Show()
    Invoke-Pump
    Start-Wait 400
    $btn = $script:ListHost.Children[0].Content.Children[0]
    $tip = $btn.ToolTip
    $tip.PlacementTarget = $btn
    $tip.IsOpen = $true
    Invoke-Pump
    Start-Wait 500
    if ($tip.IsOpen) {
        $bTop = $btn.PointToScreen([System.Windows.Point]::new(0, 0))
        $bEnd = $btn.PointToScreen([System.Windows.Point]::new($btn.ActualWidth, $btn.ActualHeight))
        $tTop = $tip.PointToScreen([System.Windows.Point]::new(0, 0))
        $report.Add("tip x           : button right=$([int]$bEnd.X) tip left=$([int]$tTop.X) clearOfList=$($tTop.X -ge $bEnd.X)")
        $report.Add("tip y           : button top=$([int]$bTop.Y) tip top=$([int]$tTop.Y)")
    }
    else {
        $report.Add("tip x           : FAILED (tooltip did not open)")
    }
    $tip.IsOpen = $false
    Invoke-Pump
    # Park the sidebar against the right screen edge and confirm WPF flips the
    # tooltip to the left instead of pushing it off-screen.
    $waDip = [System.Windows.SystemParameters]::WorkArea
    $script:Win.Left = $waDip.Right - $script:Win.Width
    Invoke-Pump
    Start-Wait 300
    $tip.IsOpen = $true
    Invoke-Pump
    Start-Wait 500
    if ($tip.IsOpen) {
        $bTop2 = $btn.PointToScreen([System.Windows.Point]::new(0, 0))
        $tTop2 = $tip.PointToScreen([System.Windows.Point]::new(0, 0))
        $report.Add("tip flip        : button left=$([int]$bTop2.X) tip left=$([int]$tTop2.X) flipped=$($tTop2.X -lt $bTop2.X)")
    }
    else {
        $report.Add("tip flip        : FAILED (tooltip did not open)")
    }
    $tip.IsOpen = $false
    Invoke-Pump
    $script:Win.Hide()
    $script:Win.ShowInTaskbar = $true

    if ($Live) {
        # Reproduce the reported failure: a terminal the palette did not spawn,
        # bound by hand, with the palette holding the foreground -- exactly the
        # state a user is in when they click a command button.
        $script:Win.ShowInTaskbar = $false
        $script:Win.Show()
        Invoke-Pump
        $tag = 'PALETTE_BIND_' + [guid]::NewGuid().ToString('N').Substring(0, 6)
        Start-Process cmd.exe -ArgumentList '/k', ('title ' + $tag) | Out-Null
        $existing = [IntPtr]::Zero
        $stop = [datetime]::UtcNow.AddSeconds(12)
        while ([datetime]::UtcNow -lt $stop -and $existing -eq [IntPtr]::Zero) {
            Start-Wait 300
            foreach ($h in [Nx]::VisibleWindows()) {
                if ([Nx]::GetTitle($h) -like "*$tag*") { $existing = $h; break }
            }
        }
        $report.Add("bind window     : $existing ($([Nx]::GetClass($existing)))")
        if ($existing -ne [IntPtr]::Zero) {
            $inPicker = @(Get-WindowCandidates | Where-Object { $_.Hwnd -eq $existing })
            $report.Add("bind in picker  : listed=$($inPicker.Count -eq 1)")
            Set-Target $existing
            $report.Add("bind target set : $((Test-Target)) hwnd=$($script:Target)")
            $self = (New-Object System.Windows.Interop.WindowInteropHelper($script:Win)).Handle
            [void]$script:Win.Activate()
            [void][Nx]::FocusWindow($self)
            Start-Wait 500
            $report.Add("bind fg=palette : $([Nx]::GetForegroundWindow() -eq $self)")
            $marker = Join-Path $script:Root ("_bind_{0}.txt" -f $tag)
            if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
            $script:ChkType.IsChecked = $true
            $script:ChkEnter.IsChecked = $true
            Invoke-PaletteItem ([pscustomobject]@{ label = 'bind'; cmd = ('echo bind-ok> "{0}"' -f $marker) })
            $script:ChkEnter.IsChecked = $false
            $stop = [datetime]::UtcNow.AddSeconds(12)
            while ([datetime]::UtcNow -lt $stop -and -not (Test-Path -LiteralPath $marker)) { Start-Wait 250 }
            if (Test-Path -LiteralPath $marker) {
                $report.Add("bind insert     : OK '$((Get-Content -LiteralPath $marker -Raw).Trim())'")
                Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
            }
            else {
                $report.Add('bind insert     : FAILED (nothing reached the bound window)')
            }
            if ([Nx]::FocusWindow($existing)) { [Nx]::SendText("exit`r`n") }
            Start-Wait 300
        }
        $script:Win.Hide()
        Invoke-Pump
        $h = New-Terminal
        $report.Add("live terminal   : $h ($([Nx]::GetClass($h)))")
        if ($h -ne [IntPtr]::Zero) {
            Set-Target $h
            Start-Wait 3000   # wait for the shell to draw its first prompt
            foreach ($mode in 'type', 'paste') {
                $marker = Join-Path $env:TEMP ("palette-{0}-{1}.txt" -f $mode, [guid]::NewGuid().ToString('N').Substring(0, 8))
                $script:ChkType.IsChecked = ($mode -eq 'type')
                $script:ChkEnter.IsChecked = $true
                Invoke-PaletteItem ([pscustomobject]@{
                        label = $mode
                        cmd   = ("Set-Content -LiteralPath '{0}' -Value 'palette-{1}-ok'" -f $marker, $mode)
                    })
                $script:ChkEnter.IsChecked = $false
                $deadline = [datetime]::UtcNow.AddSeconds(12)
                while ([datetime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $marker)) { Start-Wait 250 }
                if (Test-Path -LiteralPath $marker) {
                    $report.Add("live $mode".PadRight(16) + ": OK -> " + (Get-Content -LiteralPath $marker -Raw).Trim())
                    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
                }
                else {
                    $report.Add("live $mode".PadRight(16) + ": FAILED (no marker file)")
                }
            }
            Set-DockLayout
            $report.Add("dock layout     : applied")
            # Leave no stray window behind.
            $script:ChkType.IsChecked = $true
            $script:ChkEnter.IsChecked = $true
            Invoke-PaletteItem ([pscustomobject]@{ label = 'exit'; cmd = 'exit' })
        }
    }
    $report | ForEach-Object { Write-Host $_ }
    return
}

# Everything is built and wired, so the host console has served its purpose as
# an error sink. Retire it rather than leaving a blank window in the taskbar.
if (-not $KeepConsole) { [void][Nx]::HideOwnConsole() }

[void]$script:Win.ShowDialog()

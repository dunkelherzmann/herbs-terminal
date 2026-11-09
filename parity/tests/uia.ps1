# Feature tests on Windows: reads the test copy's windows through UI Automation, the way a screen reader does, and
# prints them as JSON. Each element: control type, identifier, name, hover text, shortcut, enabled, toggle state,
# selected state, and for the terminal the text its Text pattern gives (and the text at its caret's line).
#
#   uia.ps1 -ProcessId <pid> [-Press <identifier>] [-Find <text>]
#
# -Find gives, for the terminal, the whole word around the last match of that text (foundWord).
# -Press toggles, selects or invokes the element with that identifier first, as an assistive tool would.
# Must run in the logged-in desktop session (the feature-test runner does).
param([Parameter(Mandatory)][int]$ProcessId, [string]$Press, [string]$Find)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [System.Windows.Automation.AutomationElement]
# Found by handle: UI Automation's desktop lists only windows on the virtual desktop in use, and the tests run on
# their own desktop.
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class UiaTestWindows {
    delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    public static IntPtr[] Of(uint process) {
        var found = new List<IntPtr>();
        EnumWindows((hwnd, data) => { uint pid; GetWindowThreadProcessId(hwnd, out pid); if (pid == process && IsWindowVisible(hwnd)) found.Add(hwnd); return true; }, IntPtr.Zero);
        return found.ToArray();
    }
}
'@
$windows = @([UiaTestWindows]::Of([uint32]$ProcessId) | ForEach-Object { $A::FromHandle($_) })
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
if ($windows.Count -eq 0) {
    Write-Output (ConvertTo-Json -InputObject @{ error = "no visible window of process $ProcessId" } -Compress)
    exit 0
}

function Pattern($element, $pattern) {
    $value = $null
    if ($element.TryGetCurrentPattern($pattern, [ref]$value)) { return $value }
    return $null
}

if ($Press) {
    $byId = New-Object System.Windows.Automation.PropertyCondition($A::AutomationIdProperty, $Press)
    $target = $null
    foreach ($window in $windows) { if (-not $target) { $target = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $byId) } }
    if (-not $target) { Write-Output '{"error": "no such element"}'; exit 0 }
    $toggle = Pattern $target ([System.Windows.Automation.TogglePattern]::Pattern)
    $select = Pattern $target ([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $invoke = Pattern $target ([System.Windows.Automation.InvokePattern]::Pattern)
    $expand = Pattern $target ([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    if ($toggle) { $toggle.Toggle() } elseif ($select) { $select.Select() } elseif ($invoke) { $invoke.Invoke() } elseif ($expand) { $expand.Expand() }
    else { Write-Output '{"error": "the element can''t be pressed"}'; exit 0 }
    Start-Sleep -Milliseconds 700
}

$nodes = New-Object System.Collections.Generic.List[object]
function Walk($element, [int]$depth) {
    if ($depth -gt 30 -or $nodes.Count -ge 3000) { return }
    $current = $element.Current
    $node = [ordered]@{ role = ($current.ControlType.ProgrammaticName -replace '^ControlType\.', ''); depth = $depth }
    if ($current.AutomationId) { $node.identifier = $current.AutomationId }
    if ($current.Name) { $node.name = $current.Name }
    if ($current.HelpText) { $node.help = $current.HelpText }
    if ($current.AcceleratorKey) { $node.shortcut = $current.AcceleratorKey }
    $node.enabled = [bool]$current.IsEnabled
    $toggle = Pattern $element ([System.Windows.Automation.TogglePattern]::Pattern)
    if ($toggle) { $node.toggle = [string]$toggle.Current.ToggleState }
    $select = Pattern $element ([System.Windows.Automation.SelectionItemPattern]::Pattern)
    if ($select) { $node.selected = [bool]$select.Current.IsSelected }
    $text = Pattern $element ([System.Windows.Automation.TextPattern]::Pattern)
    if ($text) {
        $node.text = $text.DocumentRange.GetText(-1)
        $caret = $text.GetSelection()
        if ($caret.Length -gt 0) {
            $line = $caret[0].Clone()
            $line.ExpandToEnclosingUnit([System.Windows.Automation.Text.TextUnit]::Line)
            $node.caretLine = $line.GetText(-1)
            if ($Find) {
                $word = $text.DocumentRange.FindText($Find, $true, $false)
                if ($word) {
                    $word.ExpandToEnclosingUnit([System.Windows.Automation.Text.TextUnit]::Word)
                    $node.foundWord = $word.GetText(-1)
                }
            }
            $node.lineRects = $line.GetBoundingRectangles().Length
        }
    }
    $nodes.Add($node)
    $child = $walker.GetFirstChild($element)
    while ($child) {
        Walk $child ($depth + 1)
        $child = $walker.GetNextSibling($child)
    }
}
foreach ($window in $windows) { Walk $window 0 }
$array = [object[]]$nodes.ToArray()
if ($array.Length -eq 0) { "[]" } else { ConvertTo-Json -InputObject $array -Depth 4 -Compress }

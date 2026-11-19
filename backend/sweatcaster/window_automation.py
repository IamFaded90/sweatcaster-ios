"""Bounded Windows UI Automation reads and actions for one user-selected window."""

import base64
import ctypes
from ctypes import wintypes as wt
import json
import os
import subprocess
from time import monotonic

from sweatcaster import window_capture

# The program is constant. Data crosses stdin as JSON and never becomes PowerShell code.
SCRIPT = r"""
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$inputData = [Console]::In.ReadToEnd() | ConvertFrom-Json
$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$inputData.hwnd)
if ($null -eq $root -or $root.Current.ProcessId -ne [int]$inputData.pid) { throw 'Vinduet er ændret.' }
$elements = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
$allowed = @('Button','Edit','Hyperlink','ComboBox','ListItem','TabItem','CheckBox','RadioButton','MenuItem')
$items = @()
$target = $null
foreach ($element in $elements) {
    try {
        $c = $element.Current
        $role = $c.ControlType.ProgrammaticName.Replace('ControlType.','')
        if ($c.IsOffscreen -or -not $c.IsEnabled -or $c.IsPassword -or $role -notin $allowed) { continue }
        $rect = $c.BoundingRectangle
        if ($rect.IsEmpty -or $rect.Width -lt 2 -or $rect.Height -lt 2) { continue }
        $id = ($element.GetRuntimeId() -join '-')
        $name = [string]$c.Name
        if ($name.Length -gt 140) { $name = $name.Substring(0,140) }
        if ($inputData.action -eq 'read') {
            if ($items.Count -lt 100) {
                $item = [ordered]@{id=$id; role=$role; name=$name}
                $toggle = $null
                if ($role -eq 'CheckBox' -and $element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern,[ref]$toggle)) {
                    $item['value'] = if (([System.Windows.Automation.TogglePattern]$toggle).Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) {'Markeret'} else {'Ikke markeret'}
                }
                $items += $item
            }
        } elseif ($id -eq [string]$inputData.target) {
            $target = $element
            break
        }
    } catch {}
}
if ($inputData.action -eq 'read') {
    ConvertTo-Json -Depth 5 -Compress -InputObject ([ordered]@{controls=@($items)})
    exit
}
if ($null -eq $target) { throw 'Kontrollen er ændret. Hent en ny plan.' }
$pattern = $null
$verified = $false
switch ($inputData.action) {
    'click' {
        if ($target.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
            ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
        } elseif ($target.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
            ([System.Windows.Automation.SelectionItemPattern]$pattern).Select()
        } elseif ($target.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) {
            ([System.Windows.Automation.TogglePattern]$pattern).Toggle()
        } elseif ($target.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) {
            ([System.Windows.Automation.ExpandCollapsePattern]$pattern).Expand()
        } else { throw 'Brug et tryk på billedet for denne kontrol.' }
    }
    'type' {
        if (-not $target.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
            throw 'Tekstfeltet understøtter ikke direkte indtastning.'
        }
        if (([System.Windows.Automation.ValuePattern]$pattern).Current.IsReadOnly) { throw 'Feltet er skrivebeskyttet.' }
        ([System.Windows.Automation.ValuePattern]$pattern).SetValue([string]$inputData.text)
        $verified = ([System.Windows.Automation.ValuePattern]$pattern).Current.Value.Equals([string]$inputData.text)
        if (-not $verified) { throw 'Feltet blev ikke udfyldt som ønsket.' }
    }
    'verify' {
        if ($target.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
            $verified = ([System.Windows.Automation.ValuePattern]$pattern).Current.Value.Equals([string]$inputData.text)
        }
    }
    default { throw 'Ukendt handling.' }
}
ConvertTo-Json -Compress -InputObject ([ordered]@{performed=$true;verified=$verified})
"""


def _call(window, action, **fields):
    if os.name != "nt":
        raise OSError("Windows er påkrævet.")
    if window_capture.state(window) != "visible":
        raise ValueError("Åbn vinduet, før agenten arbejder i det.")
    encoded = base64.b64encode(SCRIPT.encode("utf-16le")).decode("ascii")
    try:
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
            input=json.dumps({"hwnd": window.hwnd, "pid": window.pid, "action": action, **fields}).encode("utf-8"),
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=8,
            creationflags=subprocess.CREATE_NO_WINDOW, check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise OSError("Programmet svarede ikke på betjeningen. Tjek vinduet igen.") from exc
    if result.returncode:
        raise OSError("Windows kunne ikke udføre handlingen på den valgte kontrol.")
    try:
        return json.loads(result.stdout.decode("utf-8-sig"))
    except (ValueError, UnicodeError) as exc:
        raise OSError("Windows gav et ugyldigt svar.") from exc


def controls(window):
    try:
        accessible = _call(window, "read")["controls"]
        if accessible:
            return accessible
    except OSError:
        pass
    return _native_controls(window)


def _native_controls(window):
    if window_capture.state(window) != "visible":
        return []
    user = ctypes.windll.user32
    user.GetWindowLongW.restype = wt.LONG
    found = []
    deadline = monotonic() + 1

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def visit(child, _):
        if monotonic() >= deadline:
            return False
        kind = ctypes.create_unicode_buffer(40)
        user.GetClassNameW(child, kind, len(kind))
        pid = wt.DWORD()
        user.GetWindowThreadProcessId(child, ctypes.byref(pid))
        if pid.value != window.pid or not user.IsWindowVisible(child) or not user.IsWindowEnabled(child):
            return True
        styles = user.GetWindowLongW(child, -16)
        if kind.value == "Edit" and not (styles & 0x20) and not (styles & 0x800):
            role, label = "Edit", "Tekstfelt"
        elif kind.value == "Button":
            role = "CheckBox" if (styles & 0xF) in {2, 3, 5, 6} else "Button"
            text = ctypes.create_unicode_buffer(141)
            user.GetWindowTextW(child, text, len(text))
            label = text.value
        elif kind.value == "ComboBox":
            role, label = "ComboBox", "Valgliste"
        else:
            return True
        item = {"id": f"native:{int(child)}:{pid.value}:{kind.value}", "role": role, "name": label}
        if role == "CheckBox":
            result = ctypes.c_size_t()
            if user.SendMessageTimeoutW(child, 0xF0, 0, 0, 2, 100, ctypes.byref(result)):
                item["value"] = "Markeret" if result.value == 1 else "Ikke markeret"
        found.append(item)
        return len(found) < 100
    user.EnumChildWindows(wt.HWND(window.hwnd), visit, 0)
    return found if window_capture.current(window) else []


def _native_perform(window, action):
    matching = next((c for c in _native_controls(window) if c["id"] == action["target"]), None)
    if matching is None:
        raise ValueError("Kontrollen er ændret. Hent en ny plan.")
    hwnd = wt.HWND(int(action["target"].split(":")[1]))
    user = ctypes.windll.user32
    result = ctypes.c_size_t()
    verified = False
    if action["type"] in {"type", "verify"} and matching["role"] in {"Edit", "ComboBox"}:
        if action["type"] == "type":
            value = ctypes.create_unicode_buffer(action["text"])
            ok = user.SendMessageTimeoutW(hwnd, 12, 0, ctypes.byref(value), 2, 1000, ctypes.byref(result))
            if not ok or not result.value:
                raise OSError("Windows afviste teksten.")
        value = ctypes.create_unicode_buffer(len(action["text"]) + 2)
        ok = user.SendMessageTimeoutW(hwnd, 13, len(value), ctypes.byref(value), 2, 1000, ctypes.byref(result))
        verified = bool(ok and value.value == action["text"])
        if action["type"] == "type" and not verified:
            raise OSError("Feltet blev ikke udfyldt som ønsket.")
    elif action["type"] == "click" and matching["role"] in {"Button", "CheckBox"}:
        if not user.SendMessageTimeoutW(hwnd, 0xF5, 0, 0, 2, 1000, ctypes.byref(result)):
            raise OSError("Knappen svarede ikke.")
    else:
        raise ValueError("Kontrollen understøtter ikke denne handling.")
    return {"performed": True, "verified": verified}


def verify(window, target, text):
    try:
        if target.startswith("native:"):
            return _native_perform(window, {"type": "verify", "target": target, "text": text})["verified"]
        return _call(window, "verify", target=target, text=text)["verified"]
    except (OSError, ValueError, KeyError):
        return False


def perform(window, action):
    kind = action["type"]
    if kind in {"click", "type"} and action.get("target"):
        if action["target"].startswith("native:"):
            return _native_perform(window, action)
        return _call(window, kind, target=action["target"], text=action.get("text", ""))
    return window_capture.interact(window, action)

# Version: ALF Lab Builder 2.1.0
# Display changes are optional and apply only to the current desktop session.

$ALFDisplayNativeSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace ALFLab {
    public static class GuestDisplay {
        // DEVMODEW is 220 bytes; only its size, fields and dimensions are changed.
        [StructLayout(LayoutKind.Explicit, Size = 220)]
        public struct DeviceMode {
            [FieldOffset(68)] public ushort Size;
            [FieldOffset(72)] public uint Fields;
            [FieldOffset(172)] public int Width;
            [FieldOffset(176)] public int Height;
        }
        [DllImport("user32.dll", EntryPoint = "EnumDisplaySettingsW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumDisplaySettings(string device, int mode, ref DeviceMode settings);
        [DllImport("user32.dll", EntryPoint = "ChangeDisplaySettingsW", CharSet = CharSet.Unicode)]
        private static extern int ChangeDisplaySettings(ref DeviceMode settings, uint flags);
        [DllImport("user32.dll")]
        private static extern int GetSystemMetrics(int index);
        private static DeviceMode ReadMode() {
            DeviceMode mode = new DeviceMode();
            mode.Size = 220;
            if (!EnumDisplaySettings(null, -1, ref mode))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot read the current display mode.");
            return mode;
        }
        public static int[] GetSize() {
            DeviceMode mode = ReadMode();
            return new int[] { mode.Width, mode.Height };
        }
        public static bool IsRemoteSession() { return GetSystemMetrics(0x1000) != 0; }
        public static int Set1600x900() {
            DeviceMode mode = ReadMode();
            mode.Width = 1600;
            mode.Height = 900;
            mode.Fields = 0x180000;
            int result = ChangeDisplaySettings(ref mode, 2);
            return result == 0 ? ChangeDisplaySettings(ref mode, 0) : result;
        }
    }
}
'@

function Initialize-ALFGuestDisplay {
    if (-not ('ALFLab.GuestDisplay' -as [type])) { Add-Type -TypeDefinition $ALFDisplayNativeSource -ErrorAction Stop }
}
function Get-ALFGuestDisplaySize {
    Initialize-ALFGuestDisplay
    return [ALFLab.GuestDisplay]::GetSize()
}
function Test-ALFGuestRemoteDisplay {
    Initialize-ALFGuestDisplay
    return [ALFLab.GuestDisplay]::IsRemoteSession()
}
function Invoke-ALFGuestDisplayChange {
    Initialize-ALFGuestDisplay
    return [ALFLab.GuestDisplay]::Set1600x900()
}
function Set-ALFGuestDisplayResolution([string]$Role) {
    if ($Role -notin 'DC', 'Admin') { throw 'The display option is only available on the DC and admin station.' }
    $size = @(Get-ALFGuestDisplaySize)
    if ($size.Count -ne 2) { throw 'Windows did not return a valid desktop size.' }
    if ($size[0] -eq 1600 -and $size[1] -eq 900) { return 'Desktop is already 1600 x 900.' }
    if (Test-ALFGuestRemoteDisplay) {
        throw 'This resolution is controlled by RDP or VMConnect enhanced session. Select 1600 x 900 in the connection client.'
    }
    $result = Invoke-ALFGuestDisplayChange
    if ($result -ne 0) {
        $reason = switch ($result) {
            -2 { '1600 x 900 is not supported by this display adapter.' }
            1 { 'Windows requires a restart to apply this display mode.' }
            default { "Windows rejected the display change (code $result)." }
        }
        throw $reason
    }
    $size = @(Get-ALFGuestDisplaySize)
    if ($size.Count -ne 2 -or $size[0] -ne 1600 -or $size[1] -ne 900) { throw 'Windows did not apply the requested 1600 x 900 resolution.' }
    return 'Desktop set to 1600 x 900 for this session.'
}

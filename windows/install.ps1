$ErrorActionPreference = 'Stop'

$appFolder = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $appFolder 'Quota.exe'
if (-not (Test-Path $exe)) {
    throw '请将 install.ps1 放在 Quota.exe 所在目录后再运行。'
}

$startup = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startup 'Quota.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $exe
$shortcut.WorkingDirectory = $appFolder
$shortcut.Description = 'Quota — 跟随 ChatGPT 显示额度岛'
$shortcut.WindowStyle = 7
$shortcut.Save()

Start-Process -FilePath $exe -WorkingDirectory $appFolder
Write-Host 'Quota 已安装：登录 Windows 后后台启动，并跟随 ChatGPT 显示或隐藏。'

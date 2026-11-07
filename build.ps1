# ============================================================================
#  Сборка mcp-hub.exe на Windows (без внешних зависимостей — штатный csc
#  из .NET Framework). Результат: dist\mcp-hub.exe
#
#  powershell -ExecutionPolicy Bypass -File .\build.ps1
# ============================================================================
$ErrorActionPreference = 'Stop'
Set-Location -Path (Split-Path -Parent $MyInvocation.MyCommand.Path)

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path $csc)) {
    throw 'Не найден csc.exe из .NET Framework 4.x. Запусти на Windows 10/11.'
}

New-Item -ItemType Directory -Force -Path dist | Out-Null

& $csc /nologo /target:exe `
    /out:dist\mcp-hub.exe `
    /win32icon:assets\mcp-hub.ico `
    /r:System.dll `
    /resource:mcp-hub.ps1,mcp-hub.ps1 `
    src\Program.cs

if ($LASTEXITCODE -ne 0) { throw 'Сборка завершилась с ошибкой' }
Write-Host "Готово: dist\mcp-hub.exe ($((Get-Item dist\mcp-hub.exe).Length) байт)"

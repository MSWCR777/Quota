$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
python -m pip install -r requirements.txt
if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed' }
python -m PyInstaller --noconfirm --clean --windowed --onedir --name QuotaNook --distpath ../dist main.py
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
Copy-Item ../LICENSE ../dist/QuotaNook/LICENSE.txt
Copy-Item ../THIRD_PARTY_NOTICES.md ../dist/QuotaNook/
Write-Host 'Built dist/QuotaNook/QuotaNook.exe'

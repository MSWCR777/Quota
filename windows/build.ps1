$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
python -m pip install -r requirements.txt
if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed' }
python -m PyInstaller --noconfirm --clean --windowed --onedir --name Quota --distpath ../dist main.py
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
Copy-Item ../LICENSE ../dist/Quota/LICENSE.txt
Copy-Item ../THIRD_PARTY_NOTICES.md ../dist/Quota/
Copy-Item install.ps1 ../dist/Quota/
Copy-Item '安装并启动Quota.bat' ../dist/Quota/
Write-Host 'Built dist/Quota/Quota.exe'

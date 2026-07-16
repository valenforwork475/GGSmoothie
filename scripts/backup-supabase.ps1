param([string]$OutputDirectory = (Join-Path $PSScriptRoot '..\backups'),[string]$SupabaseDirectory = (Join-Path $PSScriptRoot '..\..\deploy'))
$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$target = [System.IO.Path]::GetFullPath($OutputDirectory)
if(-not (Get-Command docker -ErrorAction SilentlyContinue)){ throw 'Docker Desktop is required by Supabase CLI db dump. Install/start Docker, then run this script again.' }
docker info *> $null
if($LASTEXITCODE -ne 0){ throw 'Docker Desktop is installed but not running.' }
New-Item -ItemType Directory -Force -Path $target | Out-Null
Push-Location -LiteralPath $SupabaseDirectory
try {
npx supabase db dump --linked --file (Join-Path $target "gg-schema-$stamp.sql")
npx supabase db dump --linked --data-only --use-copy --file (Join-Path $target "gg-data-$stamp.sql")
} finally { Pop-Location }
$files = Get-ChildItem -LiteralPath $target -Filter "gg-*-$stamp.sql"
if($files.Count -ne 2 -or ($files | Where-Object Length -eq 0)){ throw 'Backup validation failed' }
$files | Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target "gg-checksums-$stamp.json") -Encoding UTF8
Write-Host "Backup complete: $target"

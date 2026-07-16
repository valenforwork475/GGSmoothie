param([Parameter(Mandatory=$true)][string]$TargetDatabaseUrl,[Parameter(Mandatory=$true)][string]$SchemaFile,[Parameter(Mandatory=$true)][string]$DataFile,[switch]$ConfirmRestore)
$ErrorActionPreference = 'Stop'
if(-not $ConfirmRestore){ throw 'Restore cancelled. Re-run with -ConfirmRestore after verifying the TARGET database URL.' }
if(-not (Test-Path -LiteralPath $SchemaFile) -or -not (Test-Path -LiteralPath $DataFile)){ throw 'Backup file not found' }
Write-Host 'Restoring into the explicitly supplied TARGET database. Production is never selected automatically.'
psql $TargetDatabaseUrl -v ON_ERROR_STOP=1 -f $SchemaFile
psql $TargetDatabaseUrl -v ON_ERROR_STOP=1 -f $DataFile
Write-Host 'Restore completed. Run application UAT against this target before use.'

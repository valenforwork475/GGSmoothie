# GG Smoothie backup and restore

Run `.\scripts\backup-supabase.ps1` to create schema, data, and SHA-256 checksum files in `backups/`.

Backups contain customer and business data. Keep them off Git and copy them to an encrypted drive or private cloud vault.

Restore into a staging database first:

```powershell
.\scripts\restore-supabase.ps1 -TargetDatabaseUrl '<staging-db-url>' -SchemaFile '<schema.sql>' -DataFile '<data.sql>' -ConfirmRestore
```

The restore script never selects production automatically. Run UAT against the restored staging project before use.

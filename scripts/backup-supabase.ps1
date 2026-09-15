param(
  [string]$ProjectRef = "evtfsbntvuqmahiskekd",
  [string]$OutputDir = "backup/supabase"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command supabase -ErrorAction SilentlyContinue)) {
  throw "Supabase CLI no está instalado. Instálalo y vuelve a ejecutar este script."
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Write-Host "[1/4] Comprobando versión de Supabase CLI..."
supabase --version

Write-Host "[2/4] Enlazando con $ProjectRef..."
supabase link --project-ref $ProjectRef

Write-Host "[3/4] Creando backup lógico..."
supabase db dump --linked -f "$OutputDir/schema.sql"
supabase db dump --linked --data-only --use-copy -f "$OutputDir/data.sql"
supabase db dump --linked --role-only -f "$OutputDir/roles.sql"

Write-Host "[4/4] Backup terminado."
Write-Host "Archivos:"
Get-ChildItem $OutputDir | Select-Object Name,Length

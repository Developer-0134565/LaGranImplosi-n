param(
  [string]$ProjectRef = "evtfsbntvuqmahiskekd",
  [string]$OutputDir = "backup/supabase"
)

$ErrorActionPreference = "Stop"

function Invoke-Checked {
  param(
    [string]$Label,
    [scriptblock]$Command
  )

  Write-Host $Label
  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "El comando anterior falló con código $LASTEXITCODE. Backup abortado."
  }
}

if (-not (Get-Command supabase -ErrorAction SilentlyContinue)) {
  throw "Supabase CLI no está instalado. Instálalo y vuelve a ejecutar este script."
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker no está instalado o no está en PATH. Supabase db dump necesita Docker Desktop."
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$schemaPath = Join-Path $OutputDir "schema.sql"
$dataPath = Join-Path $OutputDir "data.sql"
$rolesPath = Join-Path $OutputDir "roles.sql"

Remove-Item $schemaPath, $dataPath, $rolesPath -Force -ErrorAction SilentlyContinue

Write-Host "[1/5] Comprobando herramientas..."
Invoke-Checked "Supabase CLI:" { supabase --version }
Invoke-Checked "Docker Engine:" { docker info | Out-Host }

Write-Host "[2/5] Enlazando con $ProjectRef..."
Invoke-Checked "supabase link" { supabase link --project-ref $ProjectRef }

Write-Host "[3/5] Creando backup lógico..."
Invoke-Checked "Schema dump" { supabase db dump --linked -f $schemaPath }
Invoke-Checked "Data dump" { supabase db dump --linked --data-only --use-copy -f $dataPath }
Invoke-Checked "Roles dump" { supabase db dump --linked --role-only -f $rolesPath }

Write-Host "[4/5] Validando archivos..."
$files = @($schemaPath, $dataPath, $rolesPath)
foreach ($file in $files) {
  if (-not (Test-Path $file)) {
    throw "Falta el archivo de backup: $file"
  }

  $length = (Get-Item $file).Length
  if ($length -le 0) {
    throw "El archivo de backup está vacío: $file. Backup abortado."
  }
}

Write-Host "[5/5] BACKUP VALIDADO correctamente."
Write-Host "Archivos:"
Get-Item $schemaPath, $dataPath, $rolesPath |
  Select-Object Name, Length, LastWriteTime

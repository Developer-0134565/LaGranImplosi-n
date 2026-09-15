# Backup de La Gran Implosión

## Qué protege este backup

El workflow `.github/workflows/supabase-backup.yml` genera cada noche un backup lógico del proyecto Supabase:

- `roles.sql` — roles de PostgreSQL.
- `schema.sql` — esquema actual del motor.
- `data.sql` — datos actuales.

El backup se guarda como **GitHub Actions Artifact durante 90 días**. No se guarda en el repositorio para evitar meter datos de jugadores en Git.

## Activación única

En GitHub, abre:

`Settings → Secrets and variables → Actions → New repository secret`

Crea:

`SUPABASE_DB_URL`

con la cadena de conexión PostgreSQL de Supabase.

No pongas esa cadena en ningún archivo del repositorio.

## Hacer un backup ahora

Después de crear el secreto:

`Actions → Supabase backup → Run workflow`

El workflow también se ejecutará automáticamente cada día.

## Backup local manual

Desde PowerShell, en la raíz del proyecto:

```powershell
.\scripts\backup-supabase.ps1
```

El script crea `backup/supabase/` localmente. Esa carpeta está en `.gitignore` y no debe subirse a Git.

## Importante

Supabase también mantiene backups gestionados según el plan del proyecto. La documentación actual indica backups diarios para proyectos Pro/Team/Enterprise y recomienda exportaciones externas periódicas para Free. Los backups de base de datos no contienen los objetos binarios almacenados mediante Storage.

Para recuperar el motor desde un backup lógico se utilizan `schema.sql`, `data.sql` y `roles.sql` con las herramientas de PostgreSQL/Supabase CLI.

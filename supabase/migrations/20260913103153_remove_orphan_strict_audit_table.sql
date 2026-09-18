-- Remove an orphaned one-column test/audit table that is not part of the game schema.
-- It had no primary key, no dependents, no repository migration, and contained only
-- a single dark_matter=0 row. Keep this cleanup explicit in version control so the
-- database and migration history remain aligned.
drop table if exists public.strict;
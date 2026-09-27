-- ============================================================================
-- P3 ACL CLEANUP — SYSTEMIC GUARD: new functions are not born PUBLIC-executable (2026-09-26)
-- ----------------------------------------------------------------------------
-- Measured LIVE after 20260926299000 and 20260926300000:
--   * the explicit `anon` entries were removed and, after 20260926300000, PUBLIC was closed on every existing
--     function outside the 32-name client allow-list (97 -> 0 anonymous-reachable) while `authenticated` kept
--     exactly the access it had (115 functions outside the allow-list, 19 of them re-granted explicitly because
--     PUBLIC was their only source);
--   * BUT `ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` does NOT remove PostgreSQL's
--     implicit PUBLIC EXECUTE on functions: a probe function created afterwards still carried
--     `{=X/postgres, postgres=X, service_role=X}` and was therefore still anonymous-reachable.
--
-- This migration installs a DDL event trigger that revokes PUBLIC immediately after every CREATE FUNCTION /
-- CREATE PROCEDURE, which is the only mechanism that actually removes that implicit grant. It is scoped to
-- `public` and it never touches explicit grants, so a client RPC created by a future migration must — as every
-- migration of this repository already does — grant `authenticated` explicitly.
--
-- Verified by probe: `create function public.tmp()` lands as `{postgres=X, service_role=X}` -> anon no,
-- authenticated no, service_role yes (also asserted by supabase/tests/acl_surface_p3.sql).
-- ============================================================================

create or replace function public.guard_new_function_public_execute()
returns event_trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'pg_temp'
as $g$
declare
    r record;
begin
    for r in
        select c.object_identity
          from pg_event_trigger_ddl_commands() c
         where c.command_tag in ('CREATE FUNCTION', 'CREATE PROCEDURE')
           and c.schema_name = 'public'
    loop
        execute format('revoke execute on function %s from public', r.object_identity);
    end loop;
end;
$g$;

revoke all on function public.guard_new_function_public_execute() from public, anon, authenticated;

drop event trigger if exists trg_guard_new_function_public_execute;
create event trigger trg_guard_new_function_public_execute
    on ddl_command_end
    when tag in ('CREATE FUNCTION', 'CREATE PROCEDURE')
    execute function public.guard_new_function_public_execute();
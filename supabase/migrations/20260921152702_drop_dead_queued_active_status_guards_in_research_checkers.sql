-- ============================================================================
-- DROP THE DEAD QUEUED / ACTIVE STATUS GUARDS IN THE RESEARCH CHECKERS
-- (forward-only, self-verifying patcher)
-- ----------------------------------------------------------------------------
-- FINDING (LIVE audit 2026-09-21): public.research_queue.status is constrained by
--   research_queue_status_check CHECK (status = ANY (ARRAY['RESEARCHING','COMPLETED','CANCELLED']))
-- so the literals 'QUEUED' and 'ACTIVE' can never occur. Two RESEARCH-owned
-- functions nevertheless widened their single-active-job predicate to include them:
--   start_research      : upper(status)   in('RESEARCHING','QUEUED','ACTIVE')
--   can_start_research  : upper(q.status) IN ('RESEARCHING','QUEUED','ACTIVE')
-- The predicate is therefore equivalent to upper(status) = 'RESEARCHING'.
--
-- SCOPE: only these two research checkers are touched. The building / shipyard /
-- defense queues have their own status vocabularies and are deliberately NOT
-- modified. The CHECK constraint is NOT changed and no new status is invented.
--
-- GUARANTEES
--   * idempotent     — a target that no longer mentions QUEUED/ACTIVE is skipped;
--   * self-verifying — a target that still mentions them with an unexpected shape
--                      raises, so the migration rolls back instead of silently
--                      leaving a dead guard in place;
--   * the patched DDL is the verbatim pg_get_functiondef output re-executed, so
--     SECURITY DEFINER/INVOKER, search_path, ACL and the rest of the body are
--     preserved unchanged.
-- ============================================================================

do $patch$
declare
  v_sig     text;
  v_sql     text;
  v_new     text;
  v_re      text := 'upper\(([a-z_]+\.)?status\)[[:space:]]+in[[:space:]]*\([[:space:]]*''RESEARCHING''[[:space:]]*,[[:space:]]*''QUEUED''[[:space:]]*,[[:space:]]*''ACTIVE''[[:space:]]*\)';
  v_sigs    text[] := array['public.start_research(uuid,uuid,text)','public.can_start_research(uuid,uuid,text)'];
  v_touched integer := 0;
  v_left    integer;
begin
  foreach v_sig in array v_sigs loop
    v_sql := pg_get_functiondef(v_sig::regprocedure);
    v_new := regexp_replace(v_sql, v_re, 'upper(\1status) = ''RESEARCHING''', 'gi');

    if v_new = v_sql then
      if v_sql ~* '''QUEUED''' or v_sql ~* '''ACTIVE''' then
        raise exception 'PRECONDITION_FAILED: % references a dead status in an unexpected shape', v_sig;
      end if;
      raise notice 'skip: % already clean', v_sig;
    else
      if v_new ~* '''QUEUED''' or v_new ~* '''ACTIVE''' then
        raise exception 'POSTCONDITION_FAILED: % still references a dead status', v_sig;
      end if;
      if v_new !~* 'RESEARCHING' then
        raise exception 'POSTCONDITION_FAILED: % lost its RESEARCHING guard', v_sig;
      end if;
      execute v_new;
      v_touched := v_touched + 1;
      raise notice 'patched: %', v_sig;
    end if;
  end loop;

  select count(*) into v_left
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('start_research','can_start_research')
    and (p.prosrc ~* '''QUEUED''' or p.prosrc ~* '''ACTIVE''');

  if v_left > 0 then
    raise exception 'FINAL_GATE_FAILED: % research checker(s) still carry a dead status', v_left;
  end if;

  raise notice 'dead-status cleanup applied to % research checker(s)', v_touched;
end
$patch$;

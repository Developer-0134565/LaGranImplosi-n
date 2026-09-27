-- PLAYER_MESSAGES — close the wide-open development policy and the anonymous write grants (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- Measured LIVE before this migration:
--   * `player_messages` carried `GRANT INSERT, SELECT, UPDATE, DELETE, MAINTAIN` to `anon` AND
--     `authenticated`;
--   * its only policy was `player_messages_dev_access` — `FOR ALL TO anon, authenticated USING (true)` with no
--     WITH CHECK, i.e. every anonymous visitor could read, insert, update and delete every direct message
--     (INSERT uses USING as WITH CHECK when none is given).
-- `player_messages` has 0 producers and 0 consumers (no function reads or writes it, `src/**` never
-- references it), so nothing in the product depends on that surface; the exposure is a pure defect.
--
-- This migration applies the same convention the sibling gameplay tables already use
-- (`espionage_reports`, `debris_fields`, `combat_debris_generations`: SELECT grant + `deny_direct_api_access`),
-- and revokes the write grants. No mechanic is added: when messaging is actually implemented it must reach the
-- table through an OWNER-SCOPED SECURITY DEFINER contract (sender/recipient from `auth.uid()`), which is a
-- documented GAP, not invented here.

drop policy if exists player_messages_dev_access on public.player_messages;

drop policy if exists deny_direct_api_access on public.player_messages;
create policy deny_direct_api_access on public.player_messages
    for all to anon, authenticated using (false);

revoke insert, update, delete, truncate, maintain on public.player_messages from anon;
revoke insert, update, delete, truncate, maintain on public.player_messages from authenticated;
grant select on public.player_messages to anon, authenticated;

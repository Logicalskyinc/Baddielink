-- Applied to the hosted BaddieLink project on 2026-11-19.
-- Keep authenticated users able to read and send group messages,
-- but prevent direct mutation, deletion, or truncation of message history.
BEGIN;

REVOKE UPDATE, DELETE, TRUNCATE
ON TABLE public.space_messages
FROM authenticated, anon, public;

COMMIT;

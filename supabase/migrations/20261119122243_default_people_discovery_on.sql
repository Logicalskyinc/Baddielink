-- Applied to the hosted BaddieLink project on 2026-11-19.
-- New accounts are discoverable by default.
-- Existing member preferences are intentionally preserved.
ALTER TABLE public.profiles
  ALTER COLUMN is_discoverable SET DEFAULT true;

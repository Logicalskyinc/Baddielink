begin;

revoke update, delete, truncate
on table public.space_messages
from authenticated, anon, public;

commit;
-- The legacy snapshot table is retained for the first import and older installations.
create table if not exists public.kinostream_library_entries (
    user_id uuid not null references auth.users(id) on delete cascade,
    entry_key text not null,
    entry jsonb not null,
    primary key (user_id, entry_key),
    constraint kinostream_entry_key_matches check (entry ->> 'key' = entry_key),
    constraint kinostream_entry_is_object check (jsonb_typeof(entry) = 'object')
);

alter table public.kinostream_library_entries enable row level security;
revoke all on public.kinostream_library_entries from anon, authenticated;
grant select, insert, update on public.kinostream_library_entries to authenticated;

create policy "Read own library entries" on public.kinostream_library_entries
    for select to authenticated using ((select auth.uid()) = user_id);
create policy "Insert own library entries" on public.kinostream_library_entries
    for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Update own library entries" on public.kinostream_library_entries
    for update to authenticated using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);

create or replace function public.merge_kinostream_library_entries(p_entries jsonb)
returns table(entry jsonb)
language plpgsql security invoker set search_path = '' as $$
declare
    current_user_id uuid := auth.uid();
    incoming jsonb;
begin
    if current_user_id is null then
        raise exception 'Authentication required' using errcode = '42501';
    end if;
    if jsonb_typeof(p_entries) is distinct from 'array' then
        raise exception 'Expected an array of entries' using errcode = '22023';
    end if;
    -- Stable ordering avoids lock-order inversions between devices.
    for incoming in select value from jsonb_array_elements(p_entries) order by value ->> 'key'
    loop
        if jsonb_typeof(incoming) is distinct from 'object'
            or coalesce(incoming ->> 'key', '') !~ '^(favorite|watchedItem|watchedEpisode|playback|metadata):.+'
            or jsonb_typeof(incoming -> 'modifiedAt') is distinct from 'number'
            or (incoming ->> 'modifiedAt')::numeric < 0
            or coalesce(incoming ->> 'changeID', '') = ''
            or jsonb_typeof(incoming -> 'deleted') is distinct from 'boolean'
        then
            raise exception 'Invalid library entry' using errcode = '22023';
        end if;
        insert into public.kinostream_library_entries as existing (user_id, entry_key, entry)
        values (current_user_id, incoming ->> 'key', incoming)
        on conflict (user_id, entry_key) do update set entry = excluded.entry
        where (excluded.entry ->> 'modifiedAt')::numeric > (existing.entry ->> 'modifiedAt')::numeric
           or ((excluded.entry ->> 'modifiedAt')::numeric = (existing.entry ->> 'modifiedAt')::numeric
               and (excluded.entry ->> 'changeID') collate "C" > (existing.entry ->> 'changeID') collate "C");
    end loop;
    return query select saved.entry from public.kinostream_library_entries saved
        where saved.user_id = current_user_id order by saved.entry_key;
end;
$$;

revoke all on function public.merge_kinostream_library_entries(jsonb) from public, anon;
grant execute on function public.merge_kinostream_library_entries(jsonb) to authenticated;

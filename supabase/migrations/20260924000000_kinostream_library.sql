create table if not exists public.kinostream_library (
    user_id uuid primary key references auth.users (id) on delete cascade,
    snapshot jsonb not null default '{}'::jsonb,
    constraint kinostream_library_snapshot_is_object
        check (jsonb_typeof(snapshot) = 'object')
);

alter table public.kinostream_library enable row level security;

revoke all on table public.kinostream_library from anon, authenticated;
grant select, insert, update on table public.kinostream_library to authenticated;

drop policy if exists "Users can read their KinoStream library"
    on public.kinostream_library;
create policy "Users can read their KinoStream library"
    on public.kinostream_library
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

drop policy if exists "Users can create their KinoStream library"
    on public.kinostream_library;
create policy "Users can create their KinoStream library"
    on public.kinostream_library
    for insert
    to authenticated
    with check ((select auth.uid()) = user_id);

drop policy if exists "Users can update their KinoStream library"
    on public.kinostream_library;
create policy "Users can update their KinoStream library"
    on public.kinostream_library
    for update
    to authenticated
    using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);

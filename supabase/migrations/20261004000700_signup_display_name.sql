-- Sign-up must not fail on user-supplied metadata. profiles.display_name allows
-- 1 to 100 characters; a longer display_name in raw_user_meta_data made the
-- profile insert fail and with it the whole sign-up. Cut it to 100 characters.
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, role, display_name)
  values (
    new.id,
    'customer',
    left(
      coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), split_part(new.email, '@', 1), 'user'),
      100
    )
  );
  return new;
end;
$$;

-- Schede private: ogni giocatore vede la propria scheda completa con il suo codice,
-- degli altri vede solo il profilo pubblico (quello che va anche in TV). Il master (PIN) vede tutto.
-- Già applicato al progetto Supabase "mha-plus-ultra" il 16/11/2026: qui per riferimento.

create table if not exists public.schede_backup_20261116 as select * from public.docs where col = 'schede';
revoke all on public.schede_backup_20261116 from anon, authenticated;
alter table public.schede_backup_20261116 enable row level security;

-- scheda completa: nessun accesso diretto, solo tramite le funzioni qui sotto
create table if not exists public.schede_priv (
  id text primary key,
  data jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.schede_priv enable row level security;
revoke all on public.schede_priv from anon, authenticated;

-- codice di ogni personaggio (solo hash bcrypt)
create table if not exists public.pg_code (id text primary key, hash text not null);
alter table public.pg_code enable row level security;
revoke all on public.pg_code from anon, authenticated;

create table if not exists public.code_fail (at timestamptz not null default now());
alter table public.code_fail enable row level security;
revoke all on public.code_fail from anon, authenticated;

create or replace function public._is_master(p_pin text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
begin
  if coalesce(p_pin, '') = '' then return false; end if;
  return _pin_ok(p_pin);
end $$;

create or replace function public._code_ok(p_id text, p_code text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare h text; n int;
begin
  if coalesce(p_code, '') = '' or coalesce(p_id, '') = '' then return false; end if;
  select count(*) into n from code_fail where at > now() - interval '15 minutes';
  if n >= 30 then return false; end if;
  select hash into h from pg_code where id = p_id;
  if h is null or crypt(p_code, h) <> h then
    insert into code_fail default values;
    delete from code_fail where at < now() - interval '1 day';
    return false;
  end if;
  return true;
end $$;

-- parte pubblica: solo i campi del profilo e i valori che servono alla TV durante i combattimenti
create or replace function public._pub(p_data jsonb) returns jsonb
language sql immutable set search_path = public as $$
  select jsonb_build_object(
    'char', coalesce((select jsonb_object_agg(k, v) from jsonb_each(coalesce(p_data->'char', '{}'::jsonb)) as e(k, v)
              where k = any (array['id','name','hero','color','classe','jpName','jpReading','jpHero','player','birthday',
                                   'height','quirk','likes','blurb','photo','thumb','faceCrop','rank','hp','fc','karma',
                                   'conds','der','updatedAt'])), '{}'::jsonb) || jsonb_build_object('_locked', true),
    'updatedAt', p_data->'updatedAt')
$$;

-- valori derivati per la TV (stessa formula della pagina)
create or replace function public._der(c jsonb) returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'hpMax', greatest(10, coalesce((c->'ab'->>'R')::int, 0) * 30),
    'fcMax', greatest(10, coalesce((c->'ab'->>'V')::int, 0) * 30)
             + case when coalesce(c->'traits', '[]'::jsonb) @> '[{"en":"Battle Ready"}]' then 30 else 0 end,
    'karmaMax', coalesce((c->>'rank')::int, 1))
$$;

create or replace function public.get_sheets(p_codes jsonb default '{}'::jsonb, p_pin text default null, p_ids jsonb default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare out jsonb := '[]'::jsonb; bad jsonb := '[]'::jsonb; r record; k text; v text; n int := 0;
begin
  if _is_master(p_pin) then
    select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'data', s.data, 'at', d.updated_at)), '[]'::jsonb) into out
    from schede_priv s join docs d on d.col = 'schede' and d.id = s.id
    where p_ids is null or p_ids ? s.id;
    return jsonb_build_object('ok', true, 'master', true, 'sheets', out, 'bad', bad);
  end if;
  if jsonb_typeof(p_codes) = 'object' then
    for k, v in select * from jsonb_each_text(p_codes) loop
      n := n + 1; exit when n > 20;
      if p_ids is not null and not (p_ids ? k) then continue; end if;
      if _code_ok(k, v) then
        select s.data, d.updated_at as at into r from schede_priv s join docs d on d.col = 'schede' and d.id = s.id where s.id = k;
        if found then out := out || jsonb_build_array(jsonb_build_object('id', k, 'data', r.data, 'at', r.at)); end if;
      else
        bad := bad || to_jsonb(k);
      end if;
    end loop;
  end if;
  return jsonb_build_object('ok', true, 'master', false, 'sheets', out, 'bad', bad);
end $$;

create or replace function public.put_sheet(p_id text, p_data jsonb, p_code text default null, p_pin text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_full jsonb;
begin
  if not (_is_master(p_pin) or _code_ok(p_id, p_code)) then
    return jsonb_build_object('ok', false, 'err', 'codice');
  end if;
  if octet_length(p_data::text) > 900000 then
    return jsonb_build_object('ok', false, 'err', 'troppo_grande');
  end if;
  v_full := coalesce(p_data, '{}'::jsonb);
  v_full := jsonb_set(v_full, '{char}', (coalesce(v_full->'char', '{}'::jsonb) - '_locked') || jsonb_build_object('der', _der(v_full->'char')));
  insert into schede_priv (id, data, updated_at) values (p_id, v_full, now())
  on conflict (id) do update set data = excluded.data, updated_at = now();
  insert into docs (col, id, data, updated_at) values ('schede', p_id, _pub(v_full), now())
  on conflict (col, id) do update set data = excluded.data, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.set_pg_code(p_id text, p_code text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not _is_master(p_pin) then return jsonb_build_object('ok', false, 'err', 'pin'); end if;
  if length(coalesce(trim(p_code), '')) < 4 then return jsonb_build_object('ok', false, 'err', 'corto'); end if;
  insert into pg_code (id, hash) values (p_id, crypt(trim(p_code), gen_salt('bf')))
  on conflict (id) do update set hash = excluded.hash;
  return jsonb_build_object('ok', true);
end $$;

drop function if exists public.put_doc(text, text, jsonb, text);
create or replace function public.put_doc(p_col text, p_id text, p_data jsonb, p_pin text default null, p_code text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if p_col = 'schede' then return jsonb_build_object('ok', false, 'err', 'usa_put_sheet'); end if;
  if not (_is_master(p_pin) or (p_col = 'foto' and _code_ok(split_part(p_id, '__', 1), p_code))) then
    return jsonb_build_object('ok', false, 'err', 'pin');
  end if;
  if octet_length(p_data::text) > 900000 then
    return jsonb_build_object('ok', false, 'err', 'troppo_grande');
  end if;
  insert into docs (col, id, data, updated_at) values (p_col, p_id, coalesce(p_data, '{}'::jsonb), now())
  on conflict (col, id) do update set data = excluded.data, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

drop function if exists public.del_doc(text, text, text);
create or replace function public.del_doc(p_col text, p_id text, p_pin text default null, p_code text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not (_is_master(p_pin) or (p_col = 'foto' and _code_ok(split_part(p_id, '__', 1), p_code))) then
    return jsonb_build_object('ok', false, 'err', 'pin');
  end if;
  delete from docs where col = p_col and id = p_id;
  if p_col = 'schede' then
    delete from schede_priv where id = p_id;
    delete from pg_code where id = p_id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public._is_master(text), public._code_ok(text, text), public._pub(jsonb), public._der(jsonb) from public, anon, authenticated;
revoke all on function public.get_sheets(jsonb, text, jsonb), public.put_sheet(text, jsonb, text, text), public.set_pg_code(text, text, text),
  public.put_doc(text, text, jsonb, text, text), public.del_doc(text, text, text, text) from public;
grant execute on function public.get_sheets(jsonb, text, jsonb), public.put_sheet(text, jsonb, text, text), public.set_pg_code(text, text, text),
  public.put_doc(text, text, jsonb, text, text), public.del_doc(text, text, text, text) to anon, authenticated, service_role;

-- migrazione: la scheda completa va nella parte privata, nella tabella pubblica resta solo il profilo
insert into public.schede_priv (id, data, updated_at)
select id, jsonb_set(data, '{char}', (coalesce(data->'char', '{}'::jsonb) - '_locked') || jsonb_build_object('der', public._der(data->'char'))), updated_at
from public.docs where col = 'schede'
on conflict (id) do nothing;
update public.docs d set data = public._pub(s.data) from public.schede_priv s where d.col = 'schede' and d.id = s.id;

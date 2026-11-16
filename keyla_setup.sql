-- =====================================================================
-- keyla_setup.sql  |  Keyla Lash (site + painel admin)
-- Rode no Supabase: SQL Editor > New query > cole tudo > Run.
-- É seguro rodar mais de uma vez (não apaga nem duplica dados).
-- Pressupõe que a tabela public.agendamentos já existe (usada pelo site).
-- =====================================================================

-- 1) Quem é administrador ------------------------------------------------
create table if not exists public.keyla_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.keyla_admins enable row level security;  -- sem policies: ninguém lê pela API

create or replace function public.keyla_is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.keyla_admins where user_id = (select auth.uid()))
$$;
revoke all on function public.keyla_is_admin() from public;
grant execute on function public.keyla_is_admin() to anon, authenticated;

-- 2) Tabelas do painel ---------------------------------------------------
create table if not exists public.keyla_settings (
  key text primary key,
  value text not null default ''
);
create table if not exists public.keyla_services (
  id bigint generated always as identity primary key,
  name text not null unique,
  category text not null default 'Cílios',
  price numeric(10,2) not null check (price >= 0),
  old_price numeric(10,2) check (old_price >= 0),
  description text not null default '',
  active boolean not null default true,
  sort int not null default 99
);
create table if not exists public.keyla_photos (
  id bigint generated always as identity primary key,
  title text not null,
  price numeric(10,2),
  image_url text not null,
  fit text not null default 'cover' check (fit in ('cover','contain')),
  zoom numeric not null default 1,
  ox numeric not null default 0,
  oy numeric not null default 0,
  bright numeric not null default 100,
  contrast numeric not null default 100,
  active boolean not null default true,
  sort int not null default 99
);
create table if not exists public.keyla_blocked (
  id bigint generated always as identity primary key,
  dia date not null,
  hora time,
  motivo text not null default '',
  unique nulls not distinct (dia, hora)
);

-- 3) Acesso pela API + RLS ----------------------------------------------
grant select on public.keyla_settings, public.keyla_services, public.keyla_photos to anon;
grant select, insert, update, delete on public.keyla_settings, public.keyla_services,
  public.keyla_photos, public.keyla_blocked to authenticated;
grant select, delete on public.agendamentos to authenticated;

alter table public.keyla_settings enable row level security;
alter table public.keyla_services enable row level security;
alter table public.keyla_photos   enable row level security;
alter table public.keyla_blocked  enable row level security;

-- leitura pública só do que aparece no site
drop policy if exists keyla_settings_leitura on public.keyla_settings;
create policy keyla_settings_leitura on public.keyla_settings for select to anon, authenticated using (true);
drop policy if exists keyla_services_leitura on public.keyla_services;
create policy keyla_services_leitura on public.keyla_services for select to anon, authenticated using (active);
drop policy if exists keyla_photos_leitura on public.keyla_photos;
create policy keyla_photos_leitura on public.keyla_photos for select to anon, authenticated using (active);

-- administradora: tudo
drop policy if exists keyla_settings_admin on public.keyla_settings;
create policy keyla_settings_admin on public.keyla_settings for all to authenticated
  using ((select public.keyla_is_admin())) with check ((select public.keyla_is_admin()));
drop policy if exists keyla_services_admin on public.keyla_services;
create policy keyla_services_admin on public.keyla_services for all to authenticated
  using ((select public.keyla_is_admin())) with check ((select public.keyla_is_admin()));
drop policy if exists keyla_photos_admin on public.keyla_photos;
create policy keyla_photos_admin on public.keyla_photos for all to authenticated
  using ((select public.keyla_is_admin())) with check ((select public.keyla_is_admin()));
drop policy if exists keyla_blocked_admin on public.keyla_blocked;
create policy keyla_blocked_admin on public.keyla_blocked for all to authenticated
  using ((select public.keyla_is_admin())) with check ((select public.keyla_is_admin()));

-- agendamentos: a administradora vê e cancela (o site continua só inserindo)
drop policy if exists keyla_ag_admin_ler on public.agendamentos;
create policy keyla_ag_admin_ler on public.agendamentos for select to authenticated
  using ((select public.keyla_is_admin()));
drop policy if exists keyla_ag_admin_apagar on public.agendamentos;
create policy keyla_ag_admin_apagar on public.agendamentos for delete to authenticated
  using ((select public.keyla_is_admin()));

-- 4) Horários indisponíveis no site (reservados + bloqueados pelo admin) --
-- Devolve só horas ('08:00') ou 'DIA' (dia inteiro bloqueado); nenhum dado de cliente.
create or replace function public.keyla_horarios_indisponiveis(dia date)
returns table (hora text) language sql stable security definer set search_path = '' as $$
  select left(a.hora_agendamento::text, 5) from public.agendamentos a where a.data_agendamento = dia
  union
  select coalesce(left(b.hora::text, 5), 'DIA') from public.keyla_blocked b
   where b.dia = keyla_horarios_indisponiveis.dia
$$;
revoke all on function public.keyla_horarios_indisponiveis(date) from public;
grant execute on function public.keyla_horarios_indisponiveis(date) to anon, authenticated;

-- impede reservar um horário/dia bloqueado, mesmo por fora do site
create or replace function public.keyla_checa_bloqueio()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.keyla_blocked b
              where b.dia = new.data_agendamento
                and (b.hora is null or left(b.hora::text, 5) = left(new.hora_agendamento::text, 5))) then
    raise exception 'Horário indisponível' using errcode = '23505';
  end if;
  return new;
end $$;
revoke all on function public.keyla_checa_bloqueio() from public;
drop trigger if exists keyla_bloqueio on public.agendamentos;
create trigger keyla_bloqueio before insert on public.agendamentos
  for each row execute function public.keyla_checa_bloqueio();

-- 5) Fotos do painel (bucket público; só a administradora envia) ---------
insert into storage.buckets (id, name, public) values ('keyla-fotos', 'keyla-fotos', true)
  on conflict (id) do update set public = true;
drop policy if exists keyla_fotos_admin on storage.objects;
create policy keyla_fotos_admin on storage.objects for all to authenticated
  using (bucket_id = 'keyla-fotos' and (select public.keyla_is_admin()))
  with check (bucket_id = 'keyla-fotos' and (select public.keyla_is_admin()));

-- 6) Conteúdo inicial (só entra se ainda não existir) ---------------------
insert into public.keyla_settings (key, value) values
  ('slogan', 'Realce seu olhar.'),
  ('intro', 'Beleza, elegância e sofisticação em cada detalhe. Especialista em extensão de cílios, para valorizar ainda mais a sua beleza.'),
  ('booking_intro', 'Preencha os dados e confirmamos pelo WhatsApp.'),
  ('whatsapp', '5588996857297'),
  ('address', 'Av. Contorno Sul, Bl. 400, Apt. 104'),
  ('hours_text', 'a partir das 8h'),
  ('instagram', '@keylalash'),
  ('horarios', '08:00,14:00,19:00')
on conflict (key) do nothing;

insert into public.keyla_services (name, category, price, old_price, description, sort) values
  ('Volume Brasileiro','Cílios',80,null,'Fios em formato de Y que trazem mais volume e definição, mantendo um resultado leve e sofisticado.',1),
  ('Volume Híbrido','Cílios',80,null,'A união do fio a fio com o volume: um olhar natural, com textura e preenchimento na medida certa.',2),
  ('Volume Fox','Cílios',100,null,'Efeito de olhar alongado e levantado, com fios mais compridos no canto externo para um visual marcante.',3),
  ('Volume Glamour','Cílios',80,null,'Volume cheio e intenso, com fios mais densos e curvatura acentuada para um olhar de impacto.',4),
  ('Remoção de Cílios','Cílios',40,null,'Retirada cuidadosa das extensões, protegendo e preservando os seus fios naturais.',5),
  ('Design Simples','Sobrancelha',25,null,'Modelagem que realça o formato do seu olhar, com acabamento limpo e natural.',6),
  ('Brow Lamination','Sobrancelha',60,null,'Alinhamento dos fios para um efeito de sobrancelha cheia, definida e arrumada.',7),
  ('Epilação de Buço','Epilação',10,null,'Remoção rápida e delicada dos pelos do buço, com acabamento suave.',8),
  ('Combo Brasileiro + Design','Combos',110,115,'Volume Brasileiro + Design Simples + Epilação de Buço',9),
  ('Combo Brasileiro + Brow','Combos',135,150,'Volume Brasileiro + Brow Lamination + Epilação de Buço',10),
  ('Combo Híbrido + Design','Combos',110,115,'Volume Híbrido + Design Simples + Epilação de Buço',11),
  ('Combo Híbrido + Brow','Combos',135,150,'Volume Híbrido + Brow Lamination + Epilação de Buço',12),
  ('Combo Fox + Design','Combos',130,135,'Volume Fox + Design Simples + Epilação de Buço',13),
  ('Combo Fox + Brow','Combos',155,170,'Volume Fox + Brow Lamination + Epilação de Buço',14),
  ('Combo Glamour + Design','Combos',110,115,'Volume Glamour + Design Simples + Epilação de Buço',15),
  ('Combo Glamour + Brow','Combos',135,150,'Volume Glamour + Brow Lamination + Epilação de Buço',16)
on conflict (name) do nothing;

insert into public.keyla_photos (title, image_url, sort)
select v.t, v.u, v.s from (values
  ('Resultado','imagens/foto1.jpg.jfif',1),
  ('Resultado','imagens/foto2.jpg.jfif',2),
  ('Resultado','imagens/foto3.jpg.jfif',3)) as v(t, u, s)
where not exists (select 1 from public.keyla_photos);

-- 7) PASSO MANUAL: tornar o seu login administrador -----------------------
-- Crie o usuário em Authentication > Users (e-mail + senha), depois rode,
-- trocando pelo seu e-mail:
--
-- insert into public.keyla_admins (user_id)
-- select id from auth.users where email = 'SEU_EMAIL_AQUI' on conflict do nothing;

-- 8) Conferência (opcional): RLS ligado e policies existentes --------------
-- select relname, relrowsecurity from pg_class
--  where relnamespace = 'public'::regnamespace
--    and relname in ('agendamentos','keyla_settings','keyla_services','keyla_photos','keyla_blocked','keyla_admins');
-- select tablename, policyname, roles, cmd from pg_policies where schemaname = 'public' order by 1, 2;

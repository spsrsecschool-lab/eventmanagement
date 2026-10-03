-- 12_no_aadhaar.sql : stop requiring an Aadhaar photo per person; buyers only type each person's name.
-- Paste & run once in the Supabase SQL editor. Safe to re-run. Existing orders (and their Aadhaar photos) are unchanged.

-- ---------- public: create_order ----------
-- Price comes from ticket_types, never the client. Errors are plain codes the page maps to messages.
-- One QR code per order (admits everyone on it); qty = passes; people = qty x persons_per_unit,
-- each with a name (Aadhaar images optional, no longer asked for).
drop function if exists public.create_order(bigint,int,text,text,text,text,text,text[]);   -- pre-v2 signature (no Aadhaar)
create or replace function public.create_order(
  p_type_id bigint, p_qty int, p_buyer_name text, p_email text, p_phone text,
  p_payer_name text, p_screenshot_path text, p_names text[], p_id_paths text[]
) returns text
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  s   public.event_settings%rowtype;
  t   public.ticket_types%rowtype;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_name  text := btrim(coalesce(p_buyer_name, ''));
  v_payer text := btrim(coalesce(p_payer_name, ''));
  v_phone text := btrim(coalesce(p_phone, ''));
  v_order public.orders%rowtype;
  v_left  int; v_people int; i int; nm text;
begin
  select * into s from public.event_settings where id = 1;
  if not found or not s.sales_open
     or (s.sales_start is not null and now() < s.sales_start)
     or (s.sales_end   is not null and now() > s.sales_end) then
    raise exception 'SALES_CLOSED';
  end if;

  if p_qty is null or p_qty < 1 then raise exception 'BAD_QTY'; end if;
  if p_qty > s.max_per_order then raise exception 'MAX_PER_ORDER:%', s.max_per_order; end if;
  if length(v_name) < 2 or length(v_name) > 80 then raise exception 'BAD_NAME'; end if;
  if length(regexp_replace(v_phone, '\D', '', 'g')) < 10 or length(v_phone) > 20 then raise exception 'BAD_PHONE'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 120 then raise exception 'BAD_EMAIL'; end if;
  if length(v_payer) < 2 or length(v_payer) > 80 then raise exception 'BAD_PAYER'; end if;

  -- Lock the ticket type row: concurrent buyers of this type queue here, so seats cannot be oversold.
  select * into t from public.ticket_types where id = p_type_id and active for update;
  if not found then raise exception 'TYPE_UNAVAILABLE'; end if;
  v_people := p_qty * t.persons_per_unit;

  if p_names is null or coalesce(array_length(p_names, 1), 0) <> v_people then raise exception 'BAD_ATTENDEES'; end if;
  foreach nm in array p_names loop
    if length(btrim(coalesce(nm, ''))) < 2 or length(nm) > 80 then raise exception 'BAD_ATTENDEES'; end if;
  end loop;

  -- Aadhaar images are no longer collected (the page sends an empty list). If a list is sent, it must still be
  -- one image per person: uploaded through the public uploader, all different, never used before.
  if coalesce(array_length(p_id_paths, 1), 0) = 0 then
    p_id_paths := array_fill(null::text, array[v_people]);
  elsif array_length(p_id_paths, 1) <> v_people
     or (select count(distinct x) from unnest(p_id_paths) x) <> v_people then
    raise exception 'BAD_IDS';
  else for i in 1..v_people loop
    if p_id_paths[i] is null or p_id_paths[i] !~ '^[0-9a-f-]{36}\.jpg$'
       or not exists (select 1 from storage.objects o where o.bucket_id = 'ids' and o.name = p_id_paths[i])
       or exists (select 1 from public.tickets where id_path = p_id_paths[i]) then
      raise exception 'BAD_IDS:%', i;
    end if;
  end loop; end if;

  -- screenshot must be a path uploaded through the public uploader and not used anywhere else
  if p_screenshot_path is null or p_screenshot_path !~ '^[0-9a-f-]{36}\.jpg$'
     or not exists (select 1 from storage.objects o where o.bucket_id = 'screenshots' and o.name = p_screenshot_path)
     or exists (select 1 from public.orders where screenshot_path = p_screenshot_path)
     or exists (select 1 from public.dandiya_rentals where screenshot_path = p_screenshot_path) then
    raise exception 'BAD_SCREENSHOT';
  end if;

  v_left := t.capacity - public._seats_taken(t.id);
  if v_left <= 0 then raise exception 'SOLD_OUT'; end if;
  if p_qty > v_left then raise exception 'NOT_ENOUGH_SEATS:%', v_left; end if;

  if (select count(*) from public.orders where lower(email) = v_email and status = 'pending') >= 3 then
    raise exception 'TOO_MANY_PENDING';
  end if;

  insert into public.orders (order_no, token, ticket_code, type_id, type_name, unit_price, qty, amount,
                             buyer_name, email, phone, payer_name, screenshot_path, status, source)
  values ('ORD-' || nextval('public.order_no_seq'), public._rand_token(), public._new_ticket_code(), t.id, t.name, t.price, p_qty,
          t.price * p_qty, v_name, v_email, v_phone, v_payer, p_screenshot_path, 'pending', 'online')
  returning * into v_order;

  for i in 1..v_people loop
    insert into public.tickets (order_id, attendee_name, id_path, slot)
    values (v_order.id, btrim(p_names[i]), p_id_paths[i],
            public._slot_label(t, (i - 1) / t.persons_per_unit + 1, (i - 1) % t.persons_per_unit + 1));
  end loop;

  return v_order.token;
end $$;
revoke all on function public.create_order(bigint,int,text,text,text,text,text,text[],text[]) from public, anon, authenticated;
grant execute on function public.create_order(bigint,int,text,text,text,text,text,text[],text[]) to anon, authenticated;

-- Nobody uploads Aadhaar photos any more: close public uploads to the "ids" bucket.
-- Admins can still view (and delete) photos from older orders.
drop policy if exists "ids public upload" on storage.objects;

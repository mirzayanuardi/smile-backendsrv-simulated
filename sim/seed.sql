-- Data awal SIMULASI (dijalankan setelah semua migrasi, hanya sekali saat volume baru).
-- Mengikuti seed di tests/conftest.py. Token dummy, hanya berlaku di DB lokal:
--   node 1 (aktuator + sensor): 11111111-1111-1111-1111-111111111111  token: sim-token-node-1
--   node 2 (sensor saja)      : 22222222-2222-2222-2222-222222222222  token: sim-token-node-2

update public.nodes
   set api_token_hash = encode(sha256(convert_to(
         case id when '11111111-1111-1111-1111-111111111111' then 'sim-token-node-1'
                 else 'sim-token-node-2' end, 'UTF8')), 'hex'),
       valve_mode = 'manual', pump_mode = 'manual';

-- Lokasi kebun Bogor (Darmaga).
update public.plots set location_lat = '-6.595', location_lng = '106.8166';

-- Parameter tanah Latosol Darmaga (FAO-56), kalau migrasi belum mengisinya.
insert into public.plot_soil_water_params (plot_id, theta_fc_pct, theta_pwp_pct, p_frac, zr_mm, kc,
                                           source, valid_from)
select '00000000-0000-0000-0000-0000000000b1', 59.5, 44.5, 0.40, 400, 1.0,
       'literatur_latosol_darmaga', '2026-01-01T00:00:00Z'
where not exists (select 1 from public.plot_soil_water_params
                  where plot_id = '00000000-0000-0000-0000-0000000000b1');

delete from public.node_actuator_config;
insert into public.node_actuator_config (node_id, has_irrigation, has_fertigation,
                                         water_flow_lpm, wetted_area_m2, dose_flow_ml_per_s)
values ('11111111-1111-1111-1111-111111111111', true,  true,  1.2, 0.8, 1.5),
       ('22222222-2222-2222-2222-222222222222', false, false, null, null, null);

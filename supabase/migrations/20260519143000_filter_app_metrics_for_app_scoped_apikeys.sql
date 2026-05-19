CREATE OR REPLACE FUNCTION "public"."get_app_metrics"("org_id" "uuid", "start_date" "date", "end_date" "date") RETURNS TABLE("app_id" character varying, "date" "date", "mau" bigint, "storage" bigint, "bandwidth" bigint, "build_time_unit" bigint, "get" bigint, "fail" bigint, "install" bigint, "uninstall" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  cache_entry public.app_metrics_cache%ROWTYPE;
  caller_role text;
  caller_id uuid;
  org_exists boolean;
  org_stats_updated_at timestamp without time zone;
  v_request_apikey text;
  v_limited_to_apps character varying[];
  v_cache_ttl CONSTANT interval := INTERVAL '5 minutes'; -- NOSONAR: function-local cache TTL
  v_privileged_roles CONSTANT text[] := ARRAY['service_role', 'postgres', 'supabase_admin']; -- NOSONAR: function-local privileged role set
  v_read_key_modes CONSTANT public.key_mode[] := '{read,upload,write,all}'::public.key_mode[]; -- NOSONAR: function-local key mode set
  v_read_min_right CONSTANT public.user_min_right := 'read'::public.user_min_right;
BEGIN
  SELECT COALESCE(
    NULLIF(pg_catalog.current_setting('request.jwt.claim.role', true), ''), -- NOSONAR: request role lookup reused across overloads
    NULLIF(pg_catalog.current_setting('role', true), ''),
    NULLIF(COALESCE(session_user, current_user), '')
  ) INTO caller_role;

  IF caller_role <> ALL(v_privileged_roles) THEN
    SELECT public.get_identity_org_allowed(
      v_read_key_modes,
      get_app_metrics.org_id
    )
    INTO caller_id;

    IF caller_id IS NULL OR NOT public.check_min_rights(
      v_read_min_right,
      caller_id,
      get_app_metrics.org_id,
      NULL::character varying,
      NULL::bigint
    ) THEN
      RETURN;
    END IF;

    SELECT public.get_apikey_header() INTO v_request_apikey;
    IF v_request_apikey IS NOT NULL THEN
      SELECT ak.limited_to_apps
      INTO v_limited_to_apps
      FROM public.find_apikey_by_value(v_request_apikey) ak
      LIMIT 1;
    END IF;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.orgs
    WHERE orgs.id = get_app_metrics.org_id
  ) INTO org_exists;

  IF NOT org_exists THEN
    RETURN;
  END IF;

  SELECT o.stats_updated_at
  INTO org_stats_updated_at
  FROM public.orgs o
  WHERE o.id = get_app_metrics.org_id
  LIMIT 1;

  SELECT *
  INTO cache_entry
  FROM public.app_metrics_cache
  WHERE app_metrics_cache.org_id = get_app_metrics.org_id;

  IF cache_entry.id IS NULL
    OR cache_entry.start_date IS DISTINCT FROM get_app_metrics.start_date
    OR cache_entry.end_date IS DISTINCT FROM get_app_metrics.end_date
    OR cache_entry.cached_at IS NULL
    OR cache_entry.cached_at < (pg_catalog.now() - v_cache_ttl)
    OR (
      org_stats_updated_at IS NOT NULL
      AND pg_catalog.timezone('UTC', cache_entry.cached_at) < org_stats_updated_at
    ) THEN
    cache_entry := public.seed_get_app_metrics_caches(
      get_app_metrics.org_id,
      get_app_metrics.start_date,
      get_app_metrics.end_date
    );
  END IF;

  IF cache_entry.response IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    metrics.app_id,
    metrics.date,
    metrics.mau,
    metrics.storage,
    metrics.bandwidth,
    metrics.build_time_unit,
    metrics.get,
    metrics.fail,
    metrics.install,
    metrics.uninstall
  FROM pg_catalog.jsonb_to_recordset(cache_entry.response) AS metrics(
    app_id character varying,
    date date,
    mau bigint,
    storage bigint,
    bandwidth bigint,
    build_time_unit bigint,
    get bigint,
    fail bigint,
    install bigint,
    uninstall bigint
  )
  WHERE COALESCE(array_length(v_limited_to_apps, 1), 0) = 0
    OR metrics.app_id = ANY(v_limited_to_apps)
  ORDER BY metrics.app_id, metrics.date;
END;
$$;

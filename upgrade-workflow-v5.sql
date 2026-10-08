-- Additive extension; run AFTER the existing v4 migration on a staging copy first.
BEGIN;
CREATE TABLE IF NOT EXISTS public.sensometrix_workspace_v5 (
 id uuid PRIMARY KEY, owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 kind text NOT NULL CHECK(kind IN ('project','test','event','subject','panel','campaign','facility','media','catalog','defaults','attendance')),
 study_id uuid REFERENCES public.studies(id) ON DELETE CASCADE,
 data jsonb NOT NULL CHECK(jsonb_typeof(data)='object'), revision integer NOT NULL DEFAULT 1,
 archived boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS workspace_v5_owner_kind ON public.sensometrix_workspace_v5(owner_id,kind);
CREATE UNIQUE INDEX IF NOT EXISTS workspace_v5_test ON public.sensometrix_workspace_v5(study_id) WHERE kind='test';
CREATE UNIQUE INDEX IF NOT EXISTS workspace_v5_event ON public.sensometrix_workspace_v5(study_id) WHERE kind='event';
CREATE UNIQUE INDEX IF NOT EXISTS workspace_v5_defaults ON public.sensometrix_workspace_v5(owner_id) WHERE kind='defaults';
CREATE UNIQUE INDEX IF NOT EXISTS workspace_v5_subject_code ON public.sensometrix_workspace_v5(owner_id,(data->>'code')) WHERE kind='subject';
CREATE UNIQUE INDEX IF NOT EXISTS workspace_v5_attendance ON public.sensometrix_workspace_v5(study_id,(data->>'participant_code')) WHERE kind='attendance';
ALTER TABLE public.sensometrix_workspace_v5 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sensometrix_workspace_v5 FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.sensometrix_workspace_v5 TO authenticated;
DROP POLICY IF EXISTS workspace_v5_read ON public.sensometrix_workspace_v5;
CREATE POLICY workspace_v5_read ON public.sensometrix_workspace_v5 FOR SELECT TO authenticated
 USING(owner_id=auth.uid() AND NOT coalesce((auth.jwt()->>'is_anonymous')::boolean,false));

CREATE OR REPLACE FUNCTION public.sensometrix_workspace_save_v5(p_id uuid,p_kind text,p_study_id uuid,p_data jsonb,p_revision integer,p_archived boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE u uuid:=auth.uid(); oldrow public.sensometrix_workspace_v5; result public.sensometrix_workspace_v5; ref record; st public.studies; n integer;
BEGIN
 IF u IS NULL OR coalesce((auth.jwt()->>'is_anonymous')::boolean,false) THEN RAISE EXCEPTION 'Researcher authentication required'; END IF;
 IF p_id IS NULL OR p_kind IS NULL OR p_kind NOT IN ('project','test','event','subject','panel','campaign','facility','media','catalog','defaults')
 OR jsonb_typeof(p_data) IS DISTINCT FROM 'object' OR octet_length(p_data::text)>1000000 OR p_revision IS NULL OR p_archived IS NULL
 THEN RAISE EXCEPTION 'Invalid workspace record'; END IF;
 -- Serialize owner writes and attendance actions; prevents quota races and stale references.
 PERFORM pg_advisory_xact_lock(hashtextextended(u::text,5));
 SELECT * INTO oldrow FROM public.sensometrix_workspace_v5 WHERE id=p_id FOR UPDATE;
 IF FOUND THEN
  IF oldrow.owner_id<>u OR oldrow.kind<>p_kind OR oldrow.study_id IS DISTINCT FROM p_study_id THEN RAISE EXCEPTION 'Record unavailable'; END IF;
  IF p_revision=0 AND oldrow.revision=1 AND oldrow.data=p_data AND oldrow.archived=p_archived THEN RETURN to_jsonb(oldrow); END IF;
  IF oldrow.revision<>p_revision THEN RAISE EXCEPTION 'Version conflict. Reload before editing.'; END IF;
 ELSE
  IF p_revision<>0 THEN RAISE EXCEPTION 'Record no longer exists. Reload.'; END IF;
 END IF;
 IF length(trim(coalesce(p_data->>'name',''))) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'Name must contain 1–160 characters'; END IF;
 IF p_kind IN ('test','event') THEN
  SELECT * INTO st FROM public.studies WHERE id=p_study_id AND owner_id=u FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Study owner required'; END IF;
 ELSIF p_study_id IS NOT NULL THEN RAISE EXCEPTION 'Study reference is only for tests and events'; END IF;
 FOR ref IN SELECT * FROM (VALUES ('project_id','project'),('panel_id','panel'),('facility_id','facility')) AS t(field,kind) LOOP
  IF nullif(p_data->>ref.field,'') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.sensometrix_workspace_v5 w WHERE w.id=(p_data->>ref.field)::uuid AND w.kind=ref.kind AND w.owner_id=u AND (NOT w.archived OR oldrow.data->>ref.field=p_data->>ref.field)) THEN RAISE EXCEPTION 'Linked record unavailable: %',ref.field; END IF;
 END LOOP;
 IF p_kind='test' AND nullif(p_data->>'project_id','') IS NULL THEN RAISE EXCEPTION 'Project required'; END IF;
 IF p_kind='defaults' AND (coalesce(p_data->>'language','') NOT IN ('id','en') OR NOT EXISTS(SELECT 1 FROM pg_timezone_names WHERE name=p_data->>'timezone')) THEN RAISE EXCEPTION 'Valid default language and time zone required'; END IF;
 IF p_kind='campaign' AND coalesce(p_data->>'status','') NOT IN ('draft','recruiting','closed') THEN RAISE EXCEPTION 'Invalid campaign status'; END IF;
 IF p_kind='subject' AND length(trim(coalesce(p_data->>'code',''))) NOT BETWEEN 1 AND 80 THEN RAISE EXCEPTION 'Subject code required'; END IF;
 IF p_kind IN ('media','catalog') AND coalesce(p_data->>'image','')<>'' AND NOT ((p_data->>'image') ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$') THEN RAISE EXCEPTION 'Only embedded PNG, JPEG or WebP images are supported'; END IF;
 IF p_kind='event' THEN
  IF jsonb_typeof(p_data->'enforce_schedule') IS DISTINCT FROM 'boolean' OR jsonb_typeof(p_data->'require_checkin') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'Schedule and check-in options must be boolean'; END IF;
  IF coalesce(p_data->>'language','') NOT IN ('id','en') OR NOT EXISTS(SELECT 1 FROM pg_timezone_names WHERE name=p_data->>'timezone') THEN RAISE EXCEPTION 'Valid language and time zone required'; END IF;
  IF coalesce(p_data->>'starts_at','')='' OR coalesce(p_data->>'ends_at','')='' OR (p_data->>'ends_at')::timestamptz<=(p_data->>'starts_at')::timestamptz THEN RAISE EXCEPTION 'Event end must be after start'; END IF;
  IF jsonb_typeof(p_data->'quotas') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Quotas must be an object'; END IF;
  FOR ref IN SELECT key,value FROM jsonb_each_text(p_data->'quotas') LOOP
   IF length(trim(ref.key))=0 OR ref.value !~ '^[0-9]{1,4}$' OR ref.value::integer<1 OR ref.value::integer>200 THEN RAISE EXCEPTION 'Group quotas must be 1–200'; END IF;
  END LOOP;
  IF (EXISTS(SELECT 1 FROM public.sensometrix_workspace_v5 WHERE kind='attendance' AND study_id=p_study_id) OR EXISTS(SELECT 1 FROM public.panelist_sessions WHERE study_id=p_study_id))
   AND (p_archived IS DISTINCT FROM oldrow.archived OR p_data IS DISTINCT FROM oldrow.data) THEN RAISE EXCEPTION 'Event setup is locked after roster assignment or participant sessions'; END IF;
 END IF;
 IF p_kind='panel' AND coalesce(p_data->>'quota','')<>'' THEN n:=(p_data->>'quota')::integer; IF n NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION 'Panel target must be 1–10000'; END IF; END IF;
 INSERT INTO public.sensometrix_workspace_v5(id,owner_id,kind,study_id,data,archived) VALUES(p_id,u,p_kind,p_study_id,p_data,p_archived)
 ON CONFLICT(id) DO UPDATE SET data=excluded.data,archived=excluded.archived,revision=sensometrix_workspace_v5.revision+1,updated_at=now() RETURNING * INTO result;
 RETURN to_jsonb(result);
END $$;

CREATE OR REPLACE FUNCTION public.sensometrix_workspace_import_v5(p_kind text,p_rows jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE x jsonb;n integer:=0;
BEGIN
 IF p_kind IS NULL OR p_kind NOT IN ('subject','catalog') OR jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'Import requires 1–500 subjects or catalog samples'; END IF;
 FOR x IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
  PERFORM public.sensometrix_workspace_save_v5((x->>'id')::uuid,p_kind,NULL,x->'data',0,false);n:=n+1;
 END LOOP;
 RETURN n;
END $$;

CREATE OR REPLACE FUNCTION public.sensometrix_event_action_v5(p_study_id uuid,p_code text,p_action text,p_subject_id uuid,p_revision integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE u uuid:=auth.uid(); ev public.sensometrix_workspace_v5; ar public.sensometrix_workspace_v5; subj public.sensometrix_workspace_v5; ord public.serving_orders; d jsonb;grp text;quota integer;total integer;served integer;entry jsonb;
BEGIN
 IF u IS NULL OR coalesce((auth.jwt()->>'is_anonymous')::boolean,false) THEN RAISE EXCEPTION 'Researcher required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(u::text,5));
 IF NOT EXISTS(SELECT 1 FROM public.studies WHERE id=p_study_id AND owner_id=u AND archived_at IS NULL AND status='Berlangsung') THEN RAISE EXCEPTION 'Active study owner required'; END IF;
 SELECT * INTO ev FROM public.sensometrix_workspace_v5 WHERE kind='event' AND study_id=p_study_id AND owner_id=u AND NOT archived;
 IF NOT FOUND THEN RAISE EXCEPTION 'Configure event first'; END IF;
 SELECT * INTO ord FROM public.serving_orders WHERE study_id=p_study_id AND participant_code=p_code;
 IF NOT FOUND THEN RAISE EXCEPTION 'Participant code is not in the saved serving design'; END IF;
 SELECT * INTO ar FROM public.sensometrix_workspace_v5 WHERE kind='attendance' AND study_id=p_study_id AND data->>'participant_code'=p_code FOR UPDATE;
 IF p_revision IS NULL OR coalesce(ar.revision,0)<>p_revision THEN RAISE EXCEPTION 'Version conflict. Reload roster.'; END IF;
 d:=coalesce(ar.data,jsonb_build_object('name',p_code,'participant_code',p_code,'served',0,'history','[]'::jsonb));
 IF p_action='assign' THEN
  IF d->>'checked_in_at' IS NOT NULL THEN RAISE EXCEPTION 'Identity is locked after check-in'; END IF;
  IF p_subject_id IS NOT NULL THEN
   SELECT * INTO subj FROM public.sensometrix_workspace_v5 WHERE id=p_subject_id AND kind='subject' AND owner_id=u AND NOT archived;
   IF NOT FOUND THEN RAISE EXCEPTION 'Subject unavailable'; END IF;
   IF nullif(ev.data->>'panel_id','') IS NOT NULL AND subj.data->>'panel_id' IS DISTINCT FROM ev.data->>'panel_id' THEN RAISE EXCEPTION 'Subject must belong to event panel'; END IF;
   IF EXISTS(SELECT 1 FROM public.sensometrix_workspace_v5 WHERE kind='attendance' AND study_id=p_study_id AND id IS DISTINCT FROM ar.id AND data->>'subject_id'=p_subject_id::text) THEN RAISE EXCEPTION 'Subject already assigned in this event'; END IF;
  END IF;
  d:=d||jsonb_build_object('subject_id',p_subject_id,'group',coalesce(subj.data->>'group',''));
 ELSIF p_action='checkin' THEN
  IF d->>'checked_in_at' IS NOT NULL THEN RAISE EXCEPTION 'Participant already checked in'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.studies WHERE id=p_study_id AND status='Berlangsung') THEN RAISE EXCEPTION 'Activate study before check-in'; END IF;
  IF coalesce((ev.data->>'enforce_schedule')::boolean,false) AND (now()<(ev.data->>'starts_at')::timestamptz OR now()>=(ev.data->>'ends_at')::timestamptz) THEN RAISE EXCEPTION 'Outside scheduled event window'; END IF;
  IF nullif(ev.data->>'panel_id','') IS NOT NULL AND nullif(d->>'subject_id','') IS NULL THEN RAISE EXCEPTION 'Assign a panel subject before check-in'; END IF;
  grp:=coalesce(d->>'group','');quota:=(ev.data->'quotas'->>grp)::integer;
  SELECT count(*) INTO total FROM public.sensometrix_workspace_v5 WHERE kind='attendance' AND study_id=p_study_id AND data->>'group'=grp AND data->>'checked_in_at' IS NOT NULL;
  IF quota IS NOT NULL AND total>=quota THEN RAISE EXCEPTION 'Group quota reached'; END IF;
  d:=d||jsonb_build_object('checked_in_at',now());
 ELSIF p_action='serve' THEN
  IF d->>'checked_in_at' IS NULL THEN RAISE EXCEPTION 'Check-in is required'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.studies WHERE id=p_study_id AND status='Berlangsung') THEN RAISE EXCEPTION 'Study is not active'; END IF;
  served:=coalesce((d->>'served')::integer,0);total:=jsonb_array_length(ord.sequence);
  IF served>=total THEN RAISE EXCEPTION 'All samples have already been served'; END IF;
  d:=d||jsonb_build_object('served',served+1);
 ELSE RAISE EXCEPTION 'Unknown event action'; END IF;
 entry:=jsonb_build_object('action',p_action,'at',now(),'actor',u,'position',d->'served');
 d:=jsonb_set(d,'history',coalesce(d->'history','[]'::jsonb)||jsonb_build_array(entry));
 INSERT INTO public.sensometrix_workspace_v5(id,owner_id,kind,study_id,data) VALUES(coalesce(ar.id,gen_random_uuid()),u,'attendance',p_study_id,d)
 ON CONFLICT(id) DO UPDATE SET data=excluded.data,revision=sensometrix_workspace_v5.revision+1,updated_at=now() RETURNING * INTO ar;
 RETURN to_jsonb(ar);
END $$;

-- Enforce configured event entry conditions even when joining through the old invitation screen.
CREATE OR REPLACE FUNCTION public.sensometrix_event_entry_v5() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE ev public.sensometrix_workspace_v5;owner uuid;
BEGIN
 SELECT owner_id INTO owner FROM public.studies WHERE id=NEW.study_id;
 SELECT * INTO ev FROM public.sensometrix_workspace_v5 WHERE kind='event' AND study_id=NEW.study_id AND NOT archived;
 IF NOT FOUND THEN RETURN NEW; END IF;
 IF coalesce((ev.data->>'enforce_schedule')::boolean,false) AND (now()<(ev.data->>'starts_at')::timestamptz OR now()>=(ev.data->>'ends_at')::timestamptz) THEN RAISE EXCEPTION 'Event is outside its scheduled entry window'; END IF;
 IF coalesce((ev.data->>'require_checkin')::boolean,false) AND NOT EXISTS(SELECT 1 FROM public.sensometrix_workspace_v5 WHERE kind='attendance' AND study_id=NEW.study_id AND data->>'participant_code'=NEW.participant_code AND data->>'checked_in_at' IS NOT NULL) THEN RAISE EXCEPTION 'Check in with the event team first'; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS sensometrix_event_entry_v5 ON public.panelist_sessions;
CREATE TRIGGER sensometrix_event_entry_v5 BEFORE INSERT ON public.panelist_sessions FOR EACH ROW EXECUTE FUNCTION public.sensometrix_event_entry_v5();

CREATE OR REPLACE FUNCTION public.sensometrix_panelist_event_v5(p_session_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE sid uuid;d jsonb;
BEGIN
 SELECT study_id INTO sid FROM public.panelist_sessions WHERE id=p_session_id AND auth_user_id=auth.uid();
 IF sid IS NULL THEN RAISE EXCEPTION 'Session unavailable'; END IF;
 SELECT data INTO d FROM public.sensometrix_workspace_v5 WHERE kind='event' AND study_id=sid AND NOT archived;
 RETURN jsonb_build_object('title',coalesce(nullif(d->>'participant_name',''),(SELECT data->>'participant_name' FROM public.sensometrix_workspace_v5 WHERE kind='test' AND study_id=sid AND NOT archived)), 'instructions',d->>'instructions','language',d->>'language');
END $$;
REVOKE ALL ON FUNCTION public.sensometrix_workspace_save_v5(uuid,text,uuid,jsonb,integer,boolean),public.sensometrix_workspace_import_v5(text,jsonb),public.sensometrix_event_action_v5(uuid,text,text,uuid,integer),public.sensometrix_panelist_event_v5(uuid),public.sensometrix_event_entry_v5() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.sensometrix_workspace_save_v5(uuid,text,uuid,jsonb,integer,boolean),public.sensometrix_workspace_import_v5(text,jsonb),public.sensometrix_event_action_v5(uuid,text,text,uuid,integer),public.sensometrix_panelist_event_v5(uuid) TO authenticated;
COMMIT;

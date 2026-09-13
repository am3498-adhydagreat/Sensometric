-- Sensometrix upgrade. Run on the existing database before deploying index.html.
-- Existing tables, policies, auth functions and required columns are prerequisites.
BEGIN;
-- This migration targets the JSONB schema supplied in the database export.
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='serving_orders' AND column_name='sequence' AND data_type='jsonb')
 OR NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='serving_orders' AND column_name='blind_codes' AND data_type='jsonb')
 OR to_regprocedure('sensometrix_private.serving_text_array(jsonb)') IS NULL
 OR to_regprocedure('public.is_admin()') IS NULL THEN
  RAISE EXCEPTION 'Schema mismatch: this upgrade requires the exported Sensometrix JSONB schema and existing security functions';
 END IF;
END $$;
ALTER TABLE public.studies ADD COLUMN IF NOT EXISTS content_translations jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.samples ADD COLUMN IF NOT EXISTS content_translations jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.attributes ADD COLUMN IF NOT EXISTS content_translations jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE OR REPLACE FUNCTION public.sensometrix_create_study_v2(p_request_id uuid,p_study jsonb,p_samples jsonb,p_attributes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE u uuid:=auth.uid(); st public.studies%ROWTYPE; sm public.samples%ROWTYPE; at public.attributes%ROWTYPE; item jsonb;
BEGIN
 IF u IS NULL OR coalesce((auth.jwt()->>'is_anonymous')::boolean,false) THEN RAISE EXCEPTION 'Researcher authentication required'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION 'Request ID required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 SELECT * INTO st FROM public.studies WHERE id=p_request_id;
 IF FOUND THEN
  IF st.owner_id<>u THEN RAISE EXCEPTION 'Request ID unavailable'; END IF;
  RETURN to_jsonb(st);
 END IF;
 IF jsonb_typeof(p_samples) IS DISTINCT FROM 'array' OR jsonb_typeof(p_attributes) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Samples and questions must be arrays'; END IF;
 st:=jsonb_populate_record(NULL::public.studies,p_study);
 IF length(trim(coalesce(st.name,''))) NOT BETWEEN 1 AND 160 OR st.method NOT IN ('CLT','QDA','TRIANGLE') OR st.method IS NULL
 OR st.target_panelists IS NULL OR st.target_panelists NOT BETWEEN 1 AND 200
 OR st.replication_count IS NULL OR st.replication_count NOT BETWEEN 1 AND 5 THEN RAISE EXCEPTION 'Invalid study parameters'; END IF;
 IF jsonb_array_length(p_samples) NOT BETWEEN 2 AND 8 OR jsonb_array_length(p_attributes) NOT BETWEEN 1 AND 100
 OR (st.method='TRIANGLE' AND (jsonb_array_length(p_samples)<>2 OR jsonb_array_length(p_attributes)<>1)) THEN RAISE EXCEPTION 'Invalid sample or questionnaire count'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_samples) x GROUP BY x->>'code' HAVING count(*)>1) THEN RAISE EXCEPTION 'Duplicate sample codes'; END IF;
 INSERT INTO public.studies(id,owner_id,name,method,purpose,location,target_panelists,replication_count,start_date,status,access_code)
 VALUES(p_request_id,u,trim(st.name),st.method,coalesce(st.purpose,''),coalesce(st.location,''),st.target_panelists,st.replication_count,st.start_date,'Draft',upper(substr(replace(gen_random_uuid()::text,'-',''),1,12))) RETURNING * INTO st;
 FOR item IN SELECT value FROM jsonb_array_elements(p_samples) LOOP
  sm:=jsonb_populate_record(NULL::public.samples,item);
  IF nullif(trim(sm.name),'') IS NULL OR nullif(trim(sm.code),'') IS NULL THEN RAISE EXCEPTION 'Sample name and code required'; END IF;
  INSERT INTO public.samples(study_id,name,code,sample_type,position) VALUES(st.id,sm.name,sm.code,coalesce(sm.sample_type,'Produk uji'),coalesce(sm.position,1));
 END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(p_attributes) LOOP
  at:=jsonb_populate_record(NULL::public.attributes,item);
  IF nullif(trim(at.name),'') IS NULL OR at.question_type IS NULL OR at.question_type NOT IN ('line','numeric','text','choice','hedonic','jar','star','dropdown','multiple') OR at.min_value IS NULL OR at.max_value IS NULL OR at.min_value>at.max_value THEN RAISE EXCEPTION 'Invalid question'; END IF;
  INSERT INTO public.attributes(study_id,name,scale_type,min_value,max_value,low_anchor,high_anchor,question_type,config,position)
  VALUES(st.id,at.name,at.scale_type,at.min_value,at.max_value,coalesce(at.low_anchor,''),coalesce(at.high_anchor,''),at.question_type,coalesce(at.config,'{}'::jsonb),coalesce(at.position,1));
 END LOOP;
 RETURN to_jsonb(st);
END $$;

-- Serializes design edits against activation and session creation on the same study.
CREATE OR REPLACE FUNCTION public.sensometrix_guard_design_v2() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE sid uuid; st public.studies%ROWTYPE;
BEGIN
 IF TG_OP='DELETE' THEN sid:=OLD.study_id; ELSE sid:=NEW.study_id; END IF;
 IF TG_OP='UPDATE' AND OLD.study_id<>NEW.study_id THEN RAISE EXCEPTION 'Reassigning study content is not allowed'; END IF;
 SELECT * INTO st FROM public.studies WHERE id=sid FOR UPDATE;
 IF NOT FOUND AND TG_OP='DELETE' THEN RETURN OLD; END IF; -- allow parent-study cascade deletion
 IF NOT FOUND THEN RAISE EXCEPTION 'Study not found'; END IF;
 IF st.status<>'Draft' OR st.archived_at IS NOT NULL OR EXISTS(SELECT 1 FROM public.panelist_sessions WHERE study_id=sid) OR EXISTS(SELECT 1 FROM public.responses WHERE study_id=sid) THEN RAISE EXCEPTION 'Study design is locked'; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS sensometrix_guard_orders_v2 ON public.serving_orders;
CREATE TRIGGER sensometrix_guard_orders_v2 BEFORE INSERT OR UPDATE OR DELETE ON public.serving_orders FOR EACH ROW EXECUTE FUNCTION public.sensometrix_guard_design_v2();
DROP TRIGGER IF EXISTS sensometrix_guard_samples_v2 ON public.samples;
CREATE TRIGGER sensometrix_guard_samples_v2 BEFORE INSERT OR UPDATE OR DELETE ON public.samples FOR EACH ROW EXECUTE FUNCTION public.sensometrix_guard_design_v2();
DROP TRIGGER IF EXISTS sensometrix_guard_attributes_v2 ON public.attributes;
CREATE TRIGGER sensometrix_guard_attributes_v2 BEFORE INSERT OR UPDATE OR DELETE ON public.attributes FOR EACH ROW EXECUTE FUNCTION public.sensometrix_guard_design_v2();

CREATE OR REPLACE FUNCTION public.sensometrix_guard_session_v2() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE st public.studies%ROWTYPE;
BEGIN
 SELECT * INTO st FROM public.studies WHERE id=NEW.study_id FOR UPDATE;
 IF NOT FOUND OR st.status<>'Berlangsung' OR st.archived_at IS NOT NULL THEN RAISE EXCEPTION 'Study is not accepting panelists'; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS sensometrix_guard_session_v2 ON public.panelist_sessions;
CREATE TRIGGER sensometrix_guard_session_v2 BEFORE INSERT ON public.panelist_sessions FOR EACH ROW EXECUTE FUNCTION public.sensometrix_guard_session_v2();

CREATE OR REPLACE FUNCTION public.sensometrix_guard_study_v2() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 IF NEW.status='Draft' AND OLD.status<>'Draft' AND NOT (public.is_admin() AND NOT EXISTS(SELECT 1 FROM public.panelist_sessions WHERE study_id=OLD.id) AND NOT EXISTS(SELECT 1 FROM public.responses WHERE study_id=OLD.id)) THEN RAISE EXCEPTION 'Active study parameters are locked'; END IF;
 IF NEW.status='Berlangsung' AND OLD.status IS DISTINCT FROM NEW.status AND (NEW.method IS DISTINCT FROM OLD.method OR NEW.replication_count IS DISTINCT FROM OLD.replication_count OR NEW.target_panelists IS DISTINCT FROM OLD.target_panelists) THEN RAISE EXCEPTION 'Save study parameters before activation'; END IF;
 IF (OLD.status<>'Draft' OR EXISTS(SELECT 1 FROM public.panelist_sessions WHERE study_id=OLD.id) OR EXISTS(SELECT 1 FROM public.responses WHERE study_id=OLD.id))
 AND (NEW.method IS DISTINCT FROM OLD.method OR NEW.replication_count IS DISTINCT FROM OLD.replication_count OR NEW.target_panelists IS DISTINCT FROM OLD.target_panelists OR NEW.content_translations IS DISTINCT FROM OLD.content_translations) THEN RAISE EXCEPTION 'Active study parameters are locked'; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS sensometrix_guard_study_v2 ON public.studies;
CREATE TRIGGER sensometrix_guard_study_v2 BEFORE UPDATE ON public.studies FOR EACH ROW EXECUTE FUNCTION public.sensometrix_guard_study_v2();

CREATE OR REPLACE FUNCTION public.sensometrix_save_design_v2(p_study_id uuid,p_orders jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE st public.studies%ROWTYPE; item jsonb; ro public.serving_orders%ROWTYPE; n integer; width integer; cnt integer; r integer; segment text[]; seq text[]; blinds text[];
BEGIN
 SELECT * INTO st FROM public.studies WHERE id=p_study_id FOR UPDATE;
 IF NOT FOUND OR st.owner_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Study access denied'; END IF;
 IF st.status<>'Draft' OR st.archived_at IS NOT NULL OR EXISTS(SELECT 1 FROM public.panelist_sessions WHERE study_id=st.id) OR EXISTS(SELECT 1 FROM public.responses WHERE study_id=st.id) THEN RAISE EXCEPTION 'Study design is locked'; END IF;
 IF jsonb_typeof(p_orders) IS DISTINCT FROM 'array' OR jsonb_array_length(p_orders)<>st.target_panelists THEN RAISE EXCEPTION 'Order count must match target panelists'; END IF;
 SELECT count(*) INTO n FROM public.samples WHERE study_id=st.id; width:=CASE WHEN st.method='TRIANGLE' THEN 3 ELSE n END;
 IF n NOT BETWEEN 2 AND 8 OR (st.method='TRIANGLE' AND n<>2) THEN RAISE EXCEPTION 'Invalid sample count'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_orders) x GROUP BY x->>'participant_code' HAVING count(*)>1) THEN RAISE EXCEPTION 'Duplicate panelist code'; END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(p_orders) LOOP
  ro:=jsonb_populate_record(NULL::public.serving_orders,item);
  seq:=sensometrix_private.serving_text_array(ro.sequence);
  blinds:=sensometrix_private.serving_text_array(ro.blind_codes);
  IF nullif(trim(ro.participant_code),'') IS NULL OR cardinality(seq) IS DISTINCT FROM width*st.replication_count OR cardinality(blinds) IS DISTINCT FROM width*st.replication_count THEN RAISE EXCEPTION 'Invalid sequence length or panelist code'; END IF;
  IF EXISTS(SELECT 1 FROM unnest(seq) c WHERE c IS NULL OR NOT EXISTS(SELECT 1 FROM public.samples s WHERE s.study_id=st.id AND s.code=c)) THEN RAISE EXCEPTION 'Unknown sample code'; END IF;
  IF EXISTS(SELECT 1 FROM unnest(blinds) c WHERE c IS NULL OR c::text !~ '^[1-9][0-9]{2}$') OR (SELECT count(DISTINCT c) FROM unnest(blinds) c)<>width*st.replication_count THEN RAISE EXCEPTION 'Invalid or duplicate blind code'; END IF;
  FOR r IN 0..st.replication_count-1 LOOP
   segment:=seq[r*width+1:(r+1)*width];SELECT count(DISTINCT c) INTO cnt FROM unnest(segment) c;
   IF (st.method='TRIANGLE' AND cnt<>2) OR (st.method<>'TRIANGLE' AND cnt<>n) THEN RAISE EXCEPTION 'Invalid replication composition'; END IF;
  END LOOP;
 END LOOP;
 DELETE FROM public.serving_orders WHERE study_id=st.id;
 FOR item IN SELECT value FROM jsonb_array_elements(p_orders) LOOP
  ro:=jsonb_populate_record(NULL::public.serving_orders,item);
  INSERT INTO public.serving_orders(study_id,participant_code,sequence,blind_codes,pattern_label) VALUES(st.id,ro.participant_code,ro.sequence,ro.blind_codes,ro.pattern_label);
 END LOOP;
 RETURN jsonb_array_length(p_orders);
END $$;

CREATE OR REPLACE FUNCTION public.sensometrix_save_translations_v2(p_study_id uuid,p_study jsonb,p_samples jsonb,p_attributes jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE st public.studies%ROWTYPE; item jsonb;
BEGIN
 SELECT * INTO st FROM public.studies WHERE id=p_study_id FOR UPDATE;
 IF NOT FOUND OR st.owner_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Study access denied'; END IF;
 IF st.status<>'Draft' OR st.archived_at IS NOT NULL OR EXISTS(SELECT 1 FROM public.panelist_sessions WHERE study_id=st.id) OR EXISTS(SELECT 1 FROM public.responses WHERE study_id=st.id) THEN RAISE EXCEPTION 'Translations are locked after launch'; END IF;
 IF jsonb_typeof(p_study)<>'object' OR jsonb_typeof(p_samples)<>'array' OR jsonb_typeof(p_attributes)<>'array' THEN RAISE EXCEPTION 'Invalid translations'; END IF;
 UPDATE public.studies SET content_translations=jsonb_build_object('en',p_study) WHERE id=st.id;
 FOR item IN SELECT value FROM jsonb_array_elements(p_samples) LOOP
  UPDATE public.samples SET content_translations=jsonb_build_object('en',item->'en') WHERE id=(item->>'id')::uuid AND study_id=st.id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown sample'; END IF;
 END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(p_attributes) LOOP
  UPDATE public.attributes SET content_translations=jsonb_build_object('en',item->'en') WHERE id=(item->>'id')::uuid AND study_id=st.id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown question'; END IF;
 END LOOP;
END $$;
CREATE OR REPLACE FUNCTION public.sensometrix_panelist_translations_v2(p_session_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE sid uuid; result jsonb;
BEGIN
 SELECT study_id INTO sid FROM public.panelist_sessions WHERE id=p_session_id AND auth_user_id=auth.uid();
 IF NOT FOUND THEN RAISE EXCEPTION 'Panelist session access denied'; END IF;
 SELECT jsonb_build_object('study',s.content_translations,'attributes',coalesce((SELECT jsonb_object_agg(a.id::text,a.content_translations) FROM public.attributes a WHERE a.study_id=s.id),'{}'::jsonb)) INTO result FROM public.studies s WHERE s.id=sid;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.sensometrix_panelist_translations_v2(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sensometrix_panelist_translations_v2(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.sensometrix_create_study_v2(uuid,jsonb,jsonb,jsonb),public.sensometrix_save_design_v2(uuid,jsonb),public.sensometrix_save_translations_v2(uuid,jsonb,jsonb,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sensometrix_create_study_v2(uuid,jsonb,jsonb,jsonb),public.sensometrix_save_design_v2(uuid,jsonb),public.sensometrix_save_translations_v2(uuid,jsonb,jsonb,jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.sensometrix_guard_design_v2(),public.sensometrix_guard_session_v2(),public.sensometrix_guard_study_v2() FROM PUBLIC, anon;

-- Fail before deployment if the existing schema cannot support v3 writes.
DO $$
DECLARE item record;
BEGIN
 FOR item IN SELECT * FROM (VALUES
 ('panelist_sessions','progress'),('panelist_sessions','completed_at'),('panelist_sessions','participant_code'),
 ('responses','session_id'),('responses','sample_id'),('responses','attribute_id'),('responses','replicate_number'),
 ('responses','value_num'),('responses','value_text'),('responses','notes'),('responses','is_correct')) AS required_columns(tbl,col)
 LOOP
  IF NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=item.tbl AND column_name=item.col) THEN
   RAISE EXCEPTION 'v3 prerequisite missing: public.%.%. Restore/check the original schema before deployment.',item.tbl,item.col;
  END IF;
 END LOOP;
END $$;
-- A commit records every step, including notes when all optional answers are blank.
CREATE TABLE IF NOT EXISTS public.sensometrix_step_commits_v3(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 study_id uuid NOT NULL REFERENCES public.studies(id) ON DELETE CASCADE,
 session_id uuid NOT NULL REFERENCES public.panelist_sessions(id) ON DELETE CASCADE,
 step integer NOT NULL CHECK(step>=0),notes text,created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(session_id,step)
);
ALTER TABLE public.sensometrix_step_commits_v3 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sensometrix_step_commits_v3 FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.sensometrix_step_commits_v3 TO authenticated;
DROP POLICY IF EXISTS sensometrix_read_step_commits_v3 ON public.sensometrix_step_commits_v3;
CREATE POLICY sensometrix_read_step_commits_v3 ON public.sensometrix_step_commits_v3 FOR SELECT TO authenticated
 USING(EXISTS(SELECT 1 FROM public.studies s WHERE s.id=study_id AND s.owner_id=auth.uid()));
CREATE INDEX IF NOT EXISTS sensometrix_step_commits_study_v3 ON public.sensometrix_step_commits_v3(study_id);

-- v3 reliability. Functions below use the same response columns consumed by index.html.
-- Existing grants/RLS remain authoritative for researcher reads.
CREATE OR REPLACE FUNCTION public.sensometrix_overview_v3()
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=pg_catalog,public AS $$
 WITH visible AS (SELECT * FROM public.studies WHERE archived_at IS NULL),
 sessions AS (SELECT ps.* FROM public.panelist_sessions ps JOIN visible s ON s.id=ps.study_id)
 SELECT jsonb_build_object('studies',(SELECT count(*) FROM visible),
 'active',(SELECT count(*) FROM visible WHERE status='Berlangsung'),
 'sessions',(SELECT count(*) FROM sessions),'completed',(SELECT count(*) FROM sessions WHERE completed_at IS NOT NULL),
 'recent',coalesce((SELECT jsonb_agg(to_jsonb(s)) FROM (SELECT * FROM visible ORDER BY created_at DESC,id LIMIT 5) s),'[]'::jsonb))
$$;

CREATE OR REPLACE FUNCTION public.sensometrix_question_config_v3() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
 NEW.config:=coalesce(NEW.config,'{}'::jsonb);
 IF jsonb_typeof(NEW.config) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Question config must be an object'; END IF;
 IF NEW.config ? 'required' AND jsonb_typeof(NEW.config->'required') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'required must be boolean'; END IF;
 NEW.config:=jsonb_build_object('required',true)||NEW.config;
 IF (SELECT method FROM public.studies WHERE id=NEW.study_id)='TRIANGLE' AND NEW.config->'required'='false'::jsonb THEN RAISE EXCEPTION 'Triangle choice must be required'; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS sensometrix_question_config_v3 ON public.attributes;
CREATE TRIGGER sensometrix_question_config_v3 BEFORE INSERT OR UPDATE ON public.attributes FOR EACH ROW EXECUTE FUNCTION public.sensometrix_question_config_v3();

CREATE OR REPLACE FUNCTION public.sensometrix_save_questionnaire_v3(p_study_id uuid,p_attributes jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE st public.studies%ROWTYPE; a public.attributes%ROWTYPE; item jsonb; pos integer:=0;
BEGIN
 SELECT * INTO st FROM public.studies WHERE id=p_study_id FOR UPDATE;
 IF NOT FOUND OR st.owner_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Study access denied'; END IF;
 IF st.status<>'Draft' OR st.archived_at IS NOT NULL OR EXISTS(SELECT 1 FROM public.panelist_sessions WHERE study_id=st.id) OR EXISTS(SELECT 1 FROM public.responses WHERE study_id=st.id) THEN RAISE EXCEPTION 'Questionnaire is locked'; END IF;
 IF jsonb_typeof(p_attributes) IS DISTINCT FROM 'array' OR jsonb_array_length(p_attributes) NOT BETWEEN 1 AND 100 OR (st.method='TRIANGLE' AND jsonb_array_length(p_attributes)<>1) THEN RAISE EXCEPTION 'Invalid questionnaire size'; END IF;
 DELETE FROM public.attributes WHERE study_id=st.id;
 FOR item IN SELECT value FROM jsonb_array_elements(p_attributes) LOOP
  a:=jsonb_populate_record(NULL::public.attributes,item);pos:=pos+1;
  IF nullif(trim(a.name),'') IS NULL OR a.question_type IS NULL OR a.question_type NOT IN ('line','numeric','text','choice','hedonic','jar','star','dropdown','multiple') OR a.min_value IS NULL OR a.max_value IS NULL OR a.min_value>a.max_value THEN RAISE EXCEPTION 'Invalid question'; END IF;
  INSERT INTO public.attributes(study_id,name,scale_type,min_value,max_value,low_anchor,high_anchor,question_type,config,position)
  VALUES(st.id,a.name,a.scale_type,a.min_value,a.max_value,coalesce(a.low_anchor,''),coalesce(a.high_anchor,''),a.question_type,coalesce(a.config,'{}'::jsonb),pos);
 END LOOP;
 UPDATE public.studies SET questionnaire_version=questionnaire_version+1 WHERE id=st.id;
 RETURN pos;
END $$;

CREATE OR REPLACE FUNCTION public.sensometrix_panelist_progress_v3(p_session_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE ps public.panelist_sessions%ROWTYPE;
BEGIN
 SELECT * INTO ps FROM public.panelist_sessions WHERE id=p_session_id AND auth_user_id=auth.uid();
 IF NOT FOUND THEN RAISE EXCEPTION 'Panelist session access denied'; END IF;
 RETURN jsonb_build_object('progress',coalesce(ps.progress,0),'completed_at',ps.completed_at);
END $$;

CREATE OR REPLACE FUNCTION public.sensometrix_submit_step_v3(p_session_id uuid,p_step integer,p_answers jsonb,p_notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE ps public.panelist_sessions%ROWTYPE; st public.studies%ROWTYPE; ord public.serving_orders%ROWTYPE;
 a public.attributes%ROWTYPE; answer jsonb; v jsonb; options jsonb; typ text; n numeric; txt text; missing boolean;
 total integer; width integer; offset_index integer; rep integer; sid uuid; correct boolean; selected_code text; triplet text[]; seq text[];
BEGIN
 IF p_step IS NULL OR p_step<0 THEN RAISE EXCEPTION 'Invalid step'; END IF;
 -- Study first, then session, consistent with the design/session guards.
 SELECT s.* INTO st FROM public.studies s JOIN public.panelist_sessions p ON p.study_id=s.id WHERE p.id=p_session_id AND p.auth_user_id=auth.uid() FOR UPDATE OF s;
 IF NOT FOUND THEN RAISE EXCEPTION 'Panelist session access denied'; END IF;
 SELECT * INTO ps FROM public.panelist_sessions WHERE id=p_session_id AND auth_user_id=auth.uid() FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Panelist session access denied'; END IF;
 SELECT count(*) INTO width FROM public.samples WHERE study_id=st.id;
 IF st.method='TRIANGLE' THEN total:=st.replication_count; ELSE total:=width*st.replication_count; END IF;
 IF total IS NULL OR total<1 OR p_step>=total THEN RAISE EXCEPTION 'Invalid step'; END IF;
 -- Earlier confirmed steps are immutable, even for concurrent calls or late retries.
 IF coalesce(ps.progress,0)>p_step THEN RETURN jsonb_build_object('saved',true,'already_saved',true,'progress',ps.progress); END IF;
 IF st.status<>'Berlangsung' OR st.archived_at IS NOT NULL OR ps.completed_at IS NOT NULL OR coalesce(ps.progress,0)<>p_step THEN RAISE EXCEPTION 'Session is not accepting this step'; END IF;
 IF jsonb_typeof(p_answers) IS DISTINCT FROM 'array' OR jsonb_array_length(p_answers)>100 OR length(coalesce(p_notes,''))>10000 THEN RAISE EXCEPTION 'Invalid answer payload'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_answers) x WHERE jsonb_typeof(x)<>'object' OR NOT EXISTS(SELECT 1 FROM public.attributes qa WHERE qa.study_id=st.id AND qa.id::text=x->>'attribute_id')) THEN RAISE EXCEPTION 'Unknown question'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_answers) x GROUP BY x->>'attribute_id' HAVING count(*)>1) THEN RAISE EXCEPTION 'Duplicate question answer'; END IF;
 SELECT * INTO ord FROM public.serving_orders WHERE study_id=st.id AND participant_code=ps.participant_code;
 IF NOT FOUND THEN RAISE EXCEPTION 'Serving order missing'; END IF;
 seq:=sensometrix_private.serving_text_array(ord.sequence);
 rep:=CASE WHEN st.method='TRIANGLE' THEN p_step+1 ELSE p_step/width+1 END;
 offset_index:=CASE WHEN st.method='TRIANGLE' THEN p_step*3+1 ELSE p_step+1 END;
 IF offset_index>cardinality(seq) THEN RAISE EXCEPTION 'Incomplete serving order'; END IF;
 FOR a IN SELECT * FROM public.attributes WHERE study_id=st.id ORDER BY position,id LOOP
  SELECT value INTO answer FROM jsonb_array_elements(p_answers) WHERE value->>'attribute_id'=a.id::text;
  v:=answer->'value';typ:=coalesce(a.question_type,a.scale_type);n:=NULL;txt:=NULL;correct:=NULL;
  missing:=v IS NULL OR v='null'::jsonb OR v='[]'::jsonb OR (jsonb_typeof(v)='string' AND trim(v#>>'{}')='');
  IF missing THEN
   IF st.method='TRIANGLE' OR coalesce((a.config->>'required')::boolean,true) THEN RAISE EXCEPTION 'Required question missing: %',a.id; END IF;
   CONTINUE;
  END IF;
  options:=coalesce(a.config->'options','[]'::jsonb);
  IF st.method='TRIANGLE' OR typ IN ('line','numeric','hedonic','jar','star') OR (typ='choice' AND jsonb_array_length(options)=0) THEN
   IF jsonb_typeof(v) NOT IN ('number','string') OR (v#>>'{}') !~ '^-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$' THEN RAISE EXCEPTION 'Numeric answer required: %',a.id; END IF;
   n:=(v#>>'{}')::numeric;
   IF st.method='TRIANGLE' THEN
    IF n NOT IN (1,2,3) THEN RAISE EXCEPTION 'Invalid triangle position'; END IF;
   ELSIF n<a.min_value OR n>a.max_value OR (typ IN ('hedonic','jar','star','choice') AND n<>trunc(n)) THEN RAISE EXCEPTION 'Answer outside scale: %',a.id;
   END IF;
  ELSIF typ='multiple' THEN
   IF jsonb_typeof(v)<>'array' THEN RAISE EXCEPTION 'Multiple answer must be an array'; END IF;
   IF jsonb_array_length(options)=0 THEN SELECT jsonb_agg('Opsi '||g) INTO options FROM generate_series(1,greatest(3,least(6,a.max_value::integer))) g; END IF;
   IF EXISTS(SELECT 1 FROM jsonb_array_elements(v) x WHERE jsonb_typeof(x)<>'string' OR NOT options @> jsonb_build_array(x)) OR (SELECT count(*) FROM jsonb_array_elements(v))<>(SELECT count(DISTINCT x) FROM jsonb_array_elements(v) x) THEN RAISE EXCEPTION 'Invalid multiple selection'; END IF;
   txt:=v::text;
  ELSE
   IF jsonb_typeof(v)<>'string' THEN RAISE EXCEPTION 'Text answer required: %',a.id; END IF;
   txt:=trim(v#>>'{}');
   IF length(txt)>10000 THEN RAISE EXCEPTION 'Answer too long'; END IF;
   IF typ IN ('choice','dropdown') THEN
    IF jsonb_array_length(options)=0 THEN SELECT jsonb_agg('Opsi '||g) INTO options FROM generate_series(a.min_value::integer,a.min_value::integer+greatest(2,(a.max_value-a.min_value+1)::integer)-1) g; END IF;
    IF NOT options @> jsonb_build_array(txt) THEN RAISE EXCEPTION 'Unknown answer option'; END IF;
   END IF;
  END IF;
  IF st.method='TRIANGLE' THEN
   triplet:=seq[offset_index:offset_index+2];selected_code:=triplet[n::integer];
   correct:=(SELECT count(*)=1 FROM unnest(triplet) c WHERE c=selected_code);
   SELECT id INTO sid FROM public.samples WHERE study_id=st.id AND code=selected_code;
  ELSE SELECT id INTO sid FROM public.samples WHERE study_id=st.id AND code=seq[offset_index]; END IF;
  IF sid IS NULL THEN RAISE EXCEPTION 'Unknown serving sample'; END IF;
  INSERT INTO public.responses(study_id,session_id,sample_id,attribute_id,replicate_number,value_num,value_text,notes,is_correct)
  VALUES(st.id,ps.id,sid,a.id,rep,n,txt,p_notes,correct);
 END LOOP;
 INSERT INTO public.sensometrix_step_commits_v3(study_id,session_id,step,notes) VALUES(st.id,ps.id,p_step,p_notes);
 UPDATE public.panelist_sessions SET progress=p_step+1,completed_at=CASE WHEN p_step+1=total THEN now() ELSE NULL END WHERE id=ps.id;
 IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='panelist_sessions' AND column_name='last_active_at') THEN EXECUTE 'UPDATE public.panelist_sessions SET last_active_at=now() WHERE id=$1' USING ps.id; END IF;
 IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='panelist_sessions' AND column_name='updated_at') THEN EXECUTE 'UPDATE public.panelist_sessions SET updated_at=now() WHERE id=$1' USING ps.id; END IF;
 RETURN jsonb_build_object('saved',true,'already_saved',false,'progress',p_step+1);
END $$;

-- Required flags are included even when the legacy panelist_bundle omits config.
CREATE OR REPLACE FUNCTION public.sensometrix_panelist_translations_v2(p_session_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE sid uuid; result jsonb;
BEGIN
 SELECT study_id INTO sid FROM public.panelist_sessions WHERE id=p_session_id AND auth_user_id=auth.uid();
 IF NOT FOUND THEN RAISE EXCEPTION 'Panelist session access denied'; END IF;
 SELECT jsonb_build_object('study',s.content_translations,'attributes',coalesce((SELECT jsonb_object_agg(a.id::text,a.content_translations) FROM public.attributes a WHERE a.study_id=s.id),'{}'::jsonb),
 'required',coalesce((SELECT jsonb_object_agg(a.id::text,coalesce(a.config->'required','true'::jsonb)) FROM public.attributes a WHERE a.study_id=s.id),'{}'::jsonb)) INTO result FROM public.studies s WHERE s.id=sid;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.sensometrix_overview_v3(),public.sensometrix_save_questionnaire_v3(uuid,jsonb),public.sensometrix_panelist_progress_v3(uuid),public.sensometrix_submit_step_v3(uuid,integer,jsonb,text),public.sensometrix_question_config_v3() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.sensometrix_overview_v3(),public.sensometrix_save_questionnaire_v3(uuid,jsonb),public.sensometrix_panelist_progress_v3(uuid),public.sensometrix_submit_step_v3(uuid,integer,jsonb,text) TO authenticated;
-- Prevent clients from bypassing v3 validation through the superseded submit endpoint.
DO $$ BEGIN
 IF to_regprocedure('public.submit_panelist_step(uuid,integer,jsonb,text)') IS NOT NULL THEN
  REVOKE EXECUTE ON FUNCTION public.submit_panelist_step(uuid,integer,jsonb,text) FROM PUBLIC,anon,authenticated;
 END IF;
END $$;

CREATE OR REPLACE FUNCTION public.join_study_secure(p_access_code text, p_token text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s public.studies%rowtype; i sensometrix_private.invitations%rowtype; ps public.panelist_sessions%rowtype;
begin
 if auth.uid() is null or not coalesce((auth.jwt()->>'is_anonymous')::boolean,false) then raise exception 'Anonymous participant authentication required'; end if;
 select * into s from public.studies where upper(access_code)=upper(btrim(p_access_code)) and status='Berlangsung' for update;
 if s.id is null then raise exception 'Invalid invitation or inactive study'; end if;
 select * into i from sensometrix_private.invitations where study_id=s.id and token=btrim(p_token) and expires_at>now() for update;
 if i.study_id is null then raise exception 'Invalid or expired invitation'; end if;
 if not exists(select 1 from public.serving_orders where study_id=s.id and participant_code=i.participant_code) then raise exception 'Invitation no longer has a serving order'; end if;
 select * into ps from public.panelist_sessions where study_id=s.id and participant_code=i.participant_code for update;
 if ps.id is not null then
  if ps.auth_user_id is distinct from auth.uid() then raise exception 'Invitation already claimed. Resume in the original browser; ask the researcher if it is unavailable.'; end if;
  return ps.id;
 end if;
 if exists(select 1 from public.panelist_sessions where study_id=s.id and auth_user_id=auth.uid()) then raise exception 'This browser already has a participant session for this study'; end if;
 perform sensometrix_private.check_ready(s.id);
 insert into public.panelist_sessions(study_id,participant_code,auth_user_id,progress,last_active_at)
 values(s.id,i.participant_code,auth.uid(),0,now()) returning id into ps.id;
 return ps.id;
end $function$
;
CREATE OR REPLACE FUNCTION public.admin_reset_study_responses(p_study_id uuid, p_expected_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  selected_name text;
  response_count integer;
  session_count integer;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;

  select name into selected_name
  from public.studies
  where id = p_study_id
  for update;

  if selected_name is null then
    raise exception 'Study not found' using errcode = 'P0002';
  end if;

  if p_expected_name is null or selected_name <> trim(p_expected_name) then
    raise exception 'Study name confirmation does not match' using errcode = '22023';
  end if;

  select count(*) into response_count
  from public.responses
  where study_id = p_study_id;

  select count(*) into session_count
  from public.panelist_sessions
  where study_id = p_study_id;

  delete from sensometrix_private.submissions where session_id in (select id from public.panelist_sessions where study_id=p_study_id);
  delete from public.sensometrix_step_commits_v3 where study_id = p_study_id;
  delete from public.responses where study_id = p_study_id;
  update public.panelist_sessions
  set progress = 0,
      completed_at = null,
      last_active_at = now()
  where study_id = p_study_id;

  insert into public.admin_audit_log (
    actor_id, action, study_id, study_name, details
  ) values (
    auth.uid(), 'RESET_STUDY_RESPONSES', p_study_id, selected_name,
    jsonb_build_object('deleted_responses', response_count, 'reset_sessions', session_count)
  );

  return jsonb_build_object(
    'ok', true,
    'action', 'RESET_STUDY_RESPONSES',
    'deleted_responses', response_count,
    'reset_sessions', session_count
  );
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_delete_study(p_study_id uuid, p_expected_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  selected_name text;
  response_count integer;
  session_count integer;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;

  select name into selected_name
  from public.studies
  where id = p_study_id
  for update;

  if selected_name is null then
    raise exception 'Study not found' using errcode = 'P0002';
  end if;

  if p_expected_name is null or selected_name <> trim(p_expected_name) then
    raise exception 'Study name confirmation does not match' using errcode = '22023';
  end if;

  select count(*) into response_count
  from public.responses
  where study_id = p_study_id;

  select count(*) into session_count
  from public.panelist_sessions
  where study_id = p_study_id;

  delete from sensometrix_private.submissions where session_id in (select id from public.panelist_sessions where study_id=p_study_id);
  delete from public.responses where study_id = p_study_id;
  delete from public.panelist_sessions where study_id = p_study_id;
  update public.studies set status='Draft', archived_at=null where id=p_study_id;
  delete from public.serving_orders where study_id = p_study_id;
  delete from public.attributes where study_id = p_study_id;
  delete from public.samples where study_id = p_study_id;
  delete from public.studies where id = p_study_id;

  insert into public.admin_audit_log (
    actor_id, action, study_id, study_name, details
  ) values (
    auth.uid(), 'DELETE_STUDY', p_study_id, selected_name,
    jsonb_build_object('deleted_responses', response_count, 'deleted_sessions', session_count)
  );

  return jsonb_build_object(
    'ok', true,
    'action', 'DELETE_STUDY',
    'deleted_responses', response_count,
    'deleted_sessions', session_count
  );
end;
$function$
;
-- Remove tokens when their serving-order row is deleted, including design replacement.
CREATE OR REPLACE FUNCTION sensometrix_private.revoke_removed_invitation_v3()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 DELETE FROM sensometrix_private.invitations WHERE study_id=OLD.study_id AND participant_code=OLD.participant_code;
 RETURN OLD;
END $$;
REVOKE ALL ON FUNCTION sensometrix_private.revoke_removed_invitation_v3() FROM PUBLIC,anon,authenticated,service_role;
DROP TRIGGER IF EXISTS sensometrix_revoke_removed_invitation_v3 ON public.serving_orders;
CREATE TRIGGER sensometrix_revoke_removed_invitation_v3 AFTER DELETE ON public.serving_orders FOR EACH ROW EXECUTE FUNCTION sensometrix_private.revoke_removed_invitation_v3();
-- Clean only invitations without a serving order and without a participant session.
DELETE FROM sensometrix_private.invitations i WHERE NOT EXISTS(SELECT 1 FROM public.serving_orders o WHERE o.study_id=i.study_id AND o.participant_code=i.participant_code) AND NOT EXISTS(SELECT 1 FROM public.panelist_sessions ps WHERE ps.study_id=i.study_id AND ps.participant_code=i.participant_code);

-- Sensometrix v4. Requires upgrade.sql v3 objects. Included in combined upgrade.sql.
CREATE TABLE IF NOT EXISTS public.sensometrix_plans_v4 (
 code text PRIMARY KEY CHECK(code IN ('free','pro')),
 active_studies integer NOT NULL CHECK(active_studies>0), monthly_studies integer NOT NULL CHECK(monthly_studies>0),
 panelists integer NOT NULL CHECK(panelists BETWEEN 1 AND 200), samples integer NOT NULL CHECK(samples BETWEEN 2 AND 8),
 questions integer NOT NULL CHECK(questions BETWEEN 1 AND 100), replications integer NOT NULL CHECK(replications BETWEEN 1 AND 5)
);
INSERT INTO public.sensometrix_plans_v4 VALUES('free',1,2,30,3,10,1),('pro',10,20,200,8,100,5) ON CONFLICT DO NOTHING;
ALTER TABLE public.sensometrix_plans_v4 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sensometrix_plans_v4 FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.sensometrix_plans_v4 TO authenticated;
DROP POLICY IF EXISTS plans_read ON public.sensometrix_plans_v4;
CREATE POLICY plans_read ON public.sensometrix_plans_v4 FOR SELECT TO authenticated USING(true);
CREATE TABLE IF NOT EXISTS sensometrix_private.subscriptions_v4 (
 owner_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
 plan text NOT NULL DEFAULT 'free' REFERENCES public.sensometrix_plans_v4(code),
 expires_at timestamptz, updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(plan='free' OR expires_at IS NOT NULL)
);
CREATE TABLE IF NOT EXISTS sensometrix_private.creation_ledger_v4 (
 study_id uuid PRIMARY KEY, owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS creation_owner_month_v4 ON sensometrix_private.creation_ledger_v4(owner_id,created_at);
-- Preserve usage on re-run and after study deletion. Historical active studies remain usable.
INSERT INTO sensometrix_private.creation_ledger_v4 SELECT id,owner_id,created_at FROM public.studies ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS sensometrix_private.plan_audit_v4 (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, owner_id uuid NOT NULL, actor_id uuid,
 before_state jsonb, after_state jsonb NOT NULL, reason text NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS sensometrix_private.upgrade_requests_v4 (
 owner_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
 requested_at timestamptz NOT NULL DEFAULT now(), status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','approved','closed'))
);
REVOKE ALL ON sensometrix_private.subscriptions_v4,sensometrix_private.creation_ledger_v4,sensometrix_private.plan_audit_v4,sensometrix_private.upgrade_requests_v4 FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION sensometrix_private.plan_v4(p_owner uuid)
RETURNS public.sensometrix_plans_v4 LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT p.* FROM public.sensometrix_plans_v4 p WHERE p.code=coalesce((SELECT s.plan FROM sensometrix_private.subscriptions_v4 s WHERE s.owner_id=p_owner AND s.plan='pro' AND s.expires_at>now()),'free');
$$;
REVOKE ALL ON FUNCTION sensometrix_private.plan_v4(uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.sensometrix_account_v4()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE u uuid:=auth.uid(); p public.sensometrix_plans_v4; month_start timestamptz:=date_trunc('month',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
BEGIN
 IF u IS NULL OR coalesce((auth.jwt()->>'is_anonymous')::boolean,false) THEN RAISE EXCEPTION 'Researcher authentication required'; END IF;
 p:=sensometrix_private.plan_v4(u);
 RETURN jsonb_build_object('plan',p.code,'limits',to_jsonb(p),'catalog',(SELECT jsonb_object_agg(code,to_jsonb(x)) FROM public.sensometrix_plans_v4 x),'active',(SELECT count(*) FROM public.studies WHERE owner_id=u AND status='Berlangsung' AND archived_at IS NULL),
 'created_month',(SELECT count(*) FROM sensometrix_private.creation_ledger_v4 WHERE owner_id=u AND created_at>=month_start AND created_at<month_start+interval '1 month'),
 'resets_at',month_start+interval '1 month','expires_at',(SELECT expires_at FROM sensometrix_private.subscriptions_v4 WHERE owner_id=u AND plan='pro'),
 'request_status',(SELECT status FROM sensometrix_private.upgrade_requests_v4 WHERE owner_id=u));
END $$;

CREATE OR REPLACE FUNCTION public.sensometrix_request_pro_v4()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE u uuid:=auth.uid();
BEGIN
 IF u IS NULL OR coalesce((auth.jwt()->>'is_anonymous')::boolean,false) THEN RAISE EXCEPTION 'Researcher authentication required'; END IF;
 INSERT INTO sensometrix_private.upgrade_requests_v4(owner_id) VALUES(u)
 ON CONFLICT(owner_id) DO UPDATE SET status='pending',requested_at=CASE WHEN sensometrix_private.upgrade_requests_v4.status='pending' THEN sensometrix_private.upgrade_requests_v4.requested_at ELSE now() END;
 RETURN jsonb_build_object('status','pending');
END $$;

CREATE OR REPLACE FUNCTION public.sensometrix_admin_accounts_v4()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT coalesce(public.is_admin(),false) THEN RAISE EXCEPTION 'Administrator required'; END IF;
 RETURN coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (
 SELECT p.id,p.full_name,u.email,s.plan,s.expires_at,r.status AS request_status,r.requested_at
 FROM public.profiles p JOIN auth.users u ON u.id=p.id
 LEFT JOIN sensometrix_private.subscriptions_v4 s ON s.owner_id=p.id
 LEFT JOIN sensometrix_private.upgrade_requests_v4 r ON r.owner_id=p.id
 WHERE r.status='pending' OR s.plan='pro' ORDER BY r.requested_at DESC NULLS LAST,p.id LIMIT 200
 ) x),'[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public.sensometrix_admin_set_plan_v4(p_owner uuid,p_plan text,p_expires_at timestamptz,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE prior jsonb; result jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT coalesce(public.is_admin(),false) THEN RAISE EXCEPTION 'Administrator required'; END IF;
 IF p_plan IS NULL OR p_plan NOT IN ('free','pro') OR length(trim(coalesce(p_reason,''))) NOT BETWEEN 5 AND 500 THEN RAISE EXCEPTION 'Valid plan and reason (5–500 characters) required'; END IF;
 IF p_plan='pro' AND (p_expires_at IS NULL OR p_expires_at<=now() OR p_expires_at>now()+interval '2 years') THEN RAISE EXCEPTION 'Pro expiry must be in the next two years'; END IF;
 IF NOT EXISTS(SELECT 1 FROM auth.users WHERE id=p_owner AND NOT coalesce((raw_app_meta_data->>'provider')='anonymous',false)) THEN RAISE EXCEPTION 'Researcher account required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_owner::text,4));
 SELECT to_jsonb(s) INTO prior FROM sensometrix_private.subscriptions_v4 s WHERE owner_id=p_owner;
 INSERT INTO sensometrix_private.subscriptions_v4(owner_id,plan,expires_at) VALUES(p_owner,p_plan,CASE WHEN p_plan='pro' THEN p_expires_at END)
 ON CONFLICT(owner_id) DO UPDATE SET plan=excluded.plan,expires_at=excluded.expires_at,updated_at=now();
 SELECT to_jsonb(s) INTO result FROM sensometrix_private.subscriptions_v4 s WHERE owner_id=p_owner;
 INSERT INTO sensometrix_private.plan_audit_v4(owner_id,actor_id,before_state,after_state,reason) VALUES(p_owner,auth.uid(),prior,result,trim(p_reason));
 UPDATE sensometrix_private.upgrade_requests_v4 SET status=CASE WHEN p_plan='pro' THEN 'approved' ELSE 'closed' END WHERE owner_id=p_owner;
 RETURN result;
END $$;

-- Triggers cover RPCs AND direct REST writes. Owner lock serializes creation/activation across studies.
CREATE OR REPLACE FUNCTION public.sensometrix_quota_study_v4()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE p public.sensometrix_plans_v4; n integer; changed boolean; month_start timestamptz:=date_trunc('month',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended(NEW.owner_id::text,4));
 p:=sensometrix_private.plan_v4(NEW.owner_id);
 IF TG_OP='INSERT' THEN
  IF NEW.status<>'Draft' THEN RAISE EXCEPTION 'Create a Draft before activation'; END IF;
  SELECT count(*) INTO n FROM sensometrix_private.creation_ledger_v4 WHERE owner_id=NEW.owner_id AND created_at>=month_start AND created_at<month_start+interval '1 month';
  IF n>=p.monthly_studies THEN RAISE EXCEPTION 'PLAN_MONTHLY_LIMIT: % studies per UTC month',p.monthly_studies; END IF;
  INSERT INTO sensometrix_private.creation_ledger_v4(study_id,owner_id) VALUES(NEW.id,NEW.owner_id);
  changed:=true;
 ELSE
  IF NEW.owner_id IS DISTINCT FROM OLD.owner_id OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN RAISE EXCEPTION 'Study owner and creation date are immutable'; END IF;
  changed:=NEW.target_panelists IS DISTINCT FROM OLD.target_panelists OR NEW.replication_count IS DISTINCT FROM OLD.replication_count;
 END IF;
 IF changed AND (NEW.target_panelists>p.panelists OR NEW.replication_count>p.replications) THEN RAISE EXCEPTION 'PLAN_CAPACITY_LIMIT: maximum % panelists and % replications',p.panelists,p.replications; END IF;
 IF TG_OP='UPDATE' AND NEW.status='Berlangsung' AND NEW.archived_at IS NULL AND (OLD.status<>'Berlangsung' OR OLD.archived_at IS NOT NULL) THEN
  SELECT count(*) INTO n FROM public.studies WHERE owner_id=NEW.owner_id AND id<>NEW.id AND status='Berlangsung' AND archived_at IS NULL;
  IF n>=p.active_studies THEN RAISE EXCEPTION 'PLAN_ACTIVE_LIMIT: maximum % active studies',p.active_studies; END IF;
  IF NEW.target_panelists>p.panelists OR NEW.replication_count>p.replications OR (SELECT count(*) FROM public.samples WHERE study_id=NEW.id)>p.samples OR (SELECT count(*) FROM public.attributes WHERE study_id=NEW.id)>p.questions THEN RAISE EXCEPTION 'PLAN_CAPACITY_LIMIT: study exceeds current plan'; END IF;
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS sensometrix_quota_study_v4 ON public.studies;
CREATE TRIGGER sensometrix_quota_study_v4 BEFORE INSERT OR UPDATE ON public.studies FOR EACH ROW EXECUTE FUNCTION public.sensometrix_quota_study_v4();

CREATE OR REPLACE FUNCTION public.sensometrix_quota_content_v4()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE st public.studies%ROWTYPE; p public.sensometrix_plans_v4; n integer; cap integer;
BEGIN
 SELECT * INTO st FROM public.studies WHERE id=NEW.study_id FOR UPDATE;
 p:=sensometrix_private.plan_v4(st.owner_id);
 IF TG_TABLE_NAME='samples' THEN SELECT count(*) INTO n FROM public.samples WHERE study_id=NEW.study_id;cap:=p.samples;
 ELSIF TG_TABLE_NAME='attributes' THEN SELECT count(*) INTO n FROM public.attributes WHERE study_id=NEW.study_id;cap:=p.questions;
 ELSE SELECT count(*) INTO n FROM public.serving_orders WHERE study_id=NEW.study_id;cap:=least(p.panelists,st.target_panelists); END IF;
 IF n>=cap THEN RAISE EXCEPTION 'PLAN_CONTENT_LIMIT: maximum % rows for %',cap,TG_TABLE_NAME; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS sensometrix_quota_samples_v4 ON public.samples;
CREATE TRIGGER sensometrix_quota_samples_v4 BEFORE INSERT ON public.samples FOR EACH ROW EXECUTE FUNCTION public.sensometrix_quota_content_v4();
DROP TRIGGER IF EXISTS sensometrix_quota_questions_v4 ON public.attributes;
CREATE TRIGGER sensometrix_quota_questions_v4 BEFORE INSERT ON public.attributes FOR EACH ROW EXECUTE FUNCTION public.sensometrix_quota_content_v4();
DROP TRIGGER IF EXISTS sensometrix_quota_orders_v4 ON public.serving_orders;
CREATE TRIGGER sensometrix_quota_orders_v4 BEFORE INSERT ON public.serving_orders FOR EACH ROW EXECUTE FUNCTION public.sensometrix_quota_content_v4();

CREATE OR REPLACE FUNCTION public.sensometrix_session_cap_v4()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE target integer;
BEGIN
 SELECT target_panelists INTO target FROM public.studies WHERE id=NEW.study_id FOR UPDATE;
 IF (SELECT count(*) FROM public.panelist_sessions WHERE study_id=NEW.study_id)>=target THEN RAISE EXCEPTION 'Study panelist target reached'; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS sensometrix_session_cap_v4 ON public.panelist_sessions;
CREATE TRIGGER sensometrix_session_cap_v4 BEFORE INSERT ON public.panelist_sessions FOR EACH ROW EXECUTE FUNCTION public.sensometrix_session_cap_v4();

CREATE OR REPLACE FUNCTION public.sensometrix_duplicate_v4(p_study_id uuid,p_request_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE st public.studies%ROWTYPE; p public.sensometrix_plans_v4; sm jsonb; at jsonb; existing_owner uuid;
BEGIN
 IF auth.uid() IS NULL OR coalesce((auth.jwt()->>'is_anonymous')::boolean,false) OR NOT coalesce(public.is_study_owner(p_study_id),false) THEN RAISE EXCEPTION 'Study owner required'; END IF;
 IF p_request_id IS NULL OR p_request_id=p_study_id THEN RAISE EXCEPTION 'New request ID required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 SELECT owner_id INTO existing_owner FROM public.studies WHERE id=p_request_id;
 IF FOUND THEN
  IF existing_owner<>auth.uid() THEN RAISE EXCEPTION 'Request ID unavailable'; END IF;
  RETURN p_request_id;
 END IF;
 p:=sensometrix_private.plan_v4(auth.uid());
 IF p.code<>'pro' THEN RAISE EXCEPTION 'PLAN_PRO_REQUIRED: duplication requires Pro'; END IF;
 SELECT * INTO st FROM public.studies WHERE id=p_study_id FOR UPDATE;
 SELECT jsonb_agg(to_jsonb(s) ORDER BY position,id) INTO sm FROM public.samples s WHERE study_id=p_study_id;
 SELECT jsonb_agg(to_jsonb(a) ORDER BY position,id) INTO at FROM public.attributes a WHERE study_id=p_study_id;
 PERFORM public.sensometrix_create_study_v2(p_request_id,to_jsonb(st)||jsonb_build_object('name',left(st.name,140)||' (copy)','start_date',null),sm,at);
 UPDATE public.studies SET content_translations=st.content_translations WHERE id=p_request_id;
 UPDATE public.samples dest SET content_translations=src.content_translations FROM public.samples src WHERE src.study_id=p_study_id AND dest.study_id=p_request_id AND src.code=dest.code;
 UPDATE public.attributes dest SET content_translations=src.content_translations FROM public.attributes src WHERE src.study_id=p_study_id AND dest.study_id=p_request_id AND src.position=dest.position;
 RETURN p_request_id;
END $$;
-- Close the legacy duplicate RPC bypass too.
CREATE OR REPLACE FUNCTION public.duplicate_study_draft(p_study_id uuid)
RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $$ SELECT public.sensometrix_duplicate_v4(p_study_id,gen_random_uuid()); $$;

REVOKE ALL ON FUNCTION public.sensometrix_account_v4(), public.sensometrix_request_pro_v4(),public.sensometrix_admin_accounts_v4(),public.sensometrix_admin_set_plan_v4(uuid,text,timestamptz,text),public.sensometrix_duplicate_v4(uuid,uuid),public.duplicate_study_draft(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.sensometrix_account_v4(),public.sensometrix_request_pro_v4(),public.sensometrix_admin_accounts_v4(),public.sensometrix_admin_set_plan_v4(uuid,text,timestamptz,text),public.sensometrix_duplicate_v4(uuid,uuid),public.duplicate_study_draft(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.sensometrix_quota_study_v4(),public.sensometrix_quota_content_v4(),public.sensometrix_session_cap_v4() FROM PUBLIC,anon,authenticated;

COMMIT;

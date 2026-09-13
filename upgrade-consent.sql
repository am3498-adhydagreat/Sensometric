BEGIN;
CREATE TABLE IF NOT EXISTS sensometrix_private.panelist_consent_v1 (
 session_id uuid PRIMARY KEY REFERENCES public.panelist_sessions(id) ON DELETE CASCADE,
 auth_user_id uuid NOT NULL,
 accepted_at timestamptz NOT NULL DEFAULT now(),
 version text NOT NULL,
 language text NOT NULL CHECK(language IN ('id','en')),
 information text NOT NULL,
 statement text NOT NULL
);
REVOKE ALL ON sensometrix_private.panelist_consent_v1 FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.sensometrix_consent_v1(p_session_id uuid,p_accept boolean DEFAULT false,p_version text DEFAULT NULL,p_language text DEFAULT 'id')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE receipt sensometrix_private.panelist_consent_v1%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM public.panelist_sessions WHERE id=p_session_id AND auth_user_id=auth.uid()) THEN RAISE EXCEPTION 'Panelist session access denied'; END IF;
 IF p_accept IS TRUE THEN
  IF p_version IS DISTINCT FROM 'sensometrix-consent-v1' OR p_language IS NULL OR p_language NOT IN ('id','en') THEN RAISE EXCEPTION 'Invalid consent version or language'; END IF;
  INSERT INTO sensometrix_private.panelist_consent_v1(session_id,auth_user_id,version,language,information,statement)
  VALUES(p_session_id,auth.uid(),p_version,p_language,CASE WHEN p_language='en' THEN $eninfo$You will evaluate samples or answer questions for this study. Participation is voluntary and you may stop at any time using Exit. The organizer uses your answers for study analysis. Before tasting, ask the researcher about ingredients, allergens, procedures, and data use. Do not taste samples if ingredients are unclear or unsuitable for you.$eninfo$ ELSE $idinfo$Anda akan menilai sampel atau menjawab pertanyaan untuk studi ini. Partisipasi bersifat sukarela dan Anda dapat berhenti kapan saja melalui tombol Keluar. Jawaban digunakan untuk analisis studi oleh penyelenggara. Sebelum mencicipi sampel, tanyakan bahan, alergen, prosedur, dan penggunaan data kepada peneliti. Jangan mencicipi jika bahan belum jelas atau tidak sesuai dengan kondisi Anda.$idinfo$ END,CASE WHEN p_language='en' THEN $en$I have received an explanation from the researcher about the study purpose, procedures, risks, and data use; had an opportunity to ask questions; and voluntarily agree to participate.$en$ ELSE $id$Saya telah menerima penjelasan studi dari peneliti, termasuk tujuan, prosedur, risiko, dan penggunaan data; mendapat kesempatan bertanya; serta bersedia berpartisipasi secara sukarela.$id$ END)
  ON CONFLICT(session_id) DO NOTHING;
 END IF;
 SELECT * INTO receipt FROM sensometrix_private.panelist_consent_v1 WHERE session_id=p_session_id AND auth_user_id=auth.uid();
 RETURN jsonb_build_object('accepted',receipt.version IS NOT DISTINCT FROM 'sensometrix-consent-v1','accepted_at',receipt.accepted_at,'version',receipt.version);
END $$;
REVOKE ALL ON FUNCTION public.sensometrix_consent_v1(uuid,boolean,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.sensometrix_consent_v1(uuid,boolean,text,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.sensometrix_submit_step_v3(p_session_id uuid,p_step integer,p_answers jsonb,p_notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE ps public.panelist_sessions%ROWTYPE; st public.studies%ROWTYPE; ord public.serving_orders%ROWTYPE;
 a public.attributes%ROWTYPE; answer jsonb; v jsonb; options jsonb; typ text; n numeric; txt text; missing boolean;
 total integer; width integer; offset_index integer; rep integer; sid uuid; correct boolean; selected_code text; triplet text[]; seq text[];
BEGIN
 IF NOT EXISTS(SELECT 1 FROM sensometrix_private.panelist_consent_v1 WHERE session_id=p_session_id AND auth_user_id=auth.uid() AND version='sensometrix-consent-v1') THEN RAISE EXCEPTION 'Participant consent required'; END IF;
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

COMMIT;

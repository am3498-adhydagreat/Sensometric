BEGIN;
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

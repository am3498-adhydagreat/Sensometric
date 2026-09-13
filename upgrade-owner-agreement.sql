BEGIN;
CREATE TABLE IF NOT EXISTS sensometrix_private.owner_agreements_v1 (
 owner_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
 version text NOT NULL,
 language text NOT NULL CHECK(language IN ('id','en')),
 accepted_at timestamptz NOT NULL DEFAULT now(),
 copyright_statement text NOT NULL,
 data_statement text NOT NULL
);
REVOKE ALL ON sensometrix_private.owner_agreements_v1 FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.sensometrix_owner_agreement_v1(p_copyright boolean DEFAULT false,p_data boolean DEFAULT false,p_version text DEFAULT NULL,p_language text DEFAULT 'id')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE receipt sensometrix_private.owner_agreements_v1%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL OR coalesce((auth.jwt()->>'is_anonymous')::boolean,false) THEN RAISE EXCEPTION 'Project owner authentication required'; END IF;
 IF p_copyright IS TRUE OR p_data IS TRUE THEN
  IF p_copyright IS DISTINCT FROM true OR p_data IS DISTINCT FROM true THEN RAISE EXCEPTION 'Both owner agreements are required'; END IF;
  IF p_version IS DISTINCT FROM 'owner-terms-v1' OR p_language IS NULL OR p_language NOT IN ('id','en') THEN RAISE EXCEPTION 'Invalid agreement version or language'; END IF;
  INSERT INTO sensometrix_private.owner_agreements_v1(owner_id,version,language,copyright_statement,data_statement)
  VALUES(auth.uid(),p_version,p_language,CASE WHEN p_language='en' THEN $en$I own or have permission to use the questionnaires, images, materials, and data I upload, and will provide attribution as required by those permissions.$en$ ELSE $id$Saya memiliki hak atau izin untuk menggunakan kuesioner, gambar, materi, dan data yang saya unggah, serta akan mencantumkan atribusi sesuai izin penggunaannya.$id$ END,CASE WHEN p_language='en' THEN $en$I am responsible for explaining data collection and use to participants, limiting access as needed, protecting credentials and invitation tokens, and setting project data retention and deletion periods. I understand that exporting or sharing data requires separate access management.$en$ ELSE $id$Saya bertanggung jawab menjelaskan tujuan pengumpulan dan penggunaan data kepada panelis, membatasi akses sesuai kebutuhan, menjaga kredensial dan token undangan, serta menetapkan masa simpan dan penghapusan data proyek. Saya memahami bahwa mengekspor atau membagikan data memerlukan pengelolaan akses tersendiri.$id$ END)
  ON CONFLICT(owner_id) DO NOTHING;
 END IF;
 SELECT * INTO receipt FROM sensometrix_private.owner_agreements_v1 WHERE owner_id=auth.uid();
 RETURN jsonb_build_object('accepted',receipt.version IS NOT DISTINCT FROM 'owner-terms-v1','accepted_at',receipt.accepted_at,'version',receipt.version);
END $$;
REVOKE ALL ON FUNCTION public.sensometrix_owner_agreement_v1(boolean,boolean,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.sensometrix_owner_agreement_v1(boolean,boolean,text,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.sensometrix_require_owner_agreement_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM sensometrix_private.owner_agreements_v1 WHERE owner_id=NEW.owner_id AND version='owner-terms-v1') THEN RAISE EXCEPTION 'Project owner agreement required before creating a study'; END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.sensometrix_require_owner_agreement_v1() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS sensometrix_require_owner_agreement_v1 ON public.studies;
CREATE TRIGGER sensometrix_require_owner_agreement_v1 BEFORE INSERT ON public.studies FOR EACH ROW EXECUTE FUNCTION public.sensometrix_require_owner_agreement_v1();
COMMIT;

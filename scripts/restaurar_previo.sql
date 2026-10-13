-- Paso previo a restaurar datos.sql de scripts/respaldo.mjs en una base con las migraciones
-- ya aplicadas. Las migraciones cargan catalogos (beneficiarios, requisitos, agentes) que el
-- respaldo tambien trae: sin vaciarlos, la carga choca con llaves duplicadas.
--
--   psql "$SUPABASE_DB_URL" -1 -v ON_ERROR_STOP=1 -f scripts/restaurar_previo.sql -f <respaldo>/datos.sql
--
-- Solo para una base nueva o de prueba. En replica no corren triggers: la bitacora no se
-- duplica y su proteccion contra borrado no se activa durante la restauracion.
SET session_replication_role = replica;
DO $$
DECLARE
  r RECORD;
  v_con_filas BOOLEAN;
BEGIN
  -- Las mismas areas que vuelca el respaldo: public, auth y storage (sin sus tablas de
  -- control de version, que el respaldo no trae y no se tocan).
  -- Solo las que tienen filas: algunas tablas internas de Storage no son de postgres.
  FOR r IN SELECT schemaname, tablename FROM pg_tables WHERE schemaname IN ('public', 'auth', 'storage')
             AND tablename NOT IN ('schema_migrations', 'migrations', 'buckets_analytics', 'buckets_vectors',
               'iceberg_namespaces', 'iceberg_tables', 's3_multipart_uploads', 's3_multipart_uploads_parts', 'vector_indexes') LOOP
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.%I)', r.schemaname, r.tablename) INTO v_con_filas;
    IF v_con_filas THEN
      EXECUTE format('TRUNCATE TABLE %I.%I CASCADE', r.schemaname, r.tablename);
    END IF;
  END LOOP;
END $$;

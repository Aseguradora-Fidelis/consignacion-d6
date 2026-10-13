// Corre las pruebas SQL de supabase/tests contra la base local de `supabase start`.
// Cada archivo abre una transaccion y la revierte, asi que no deja datos.
import { spawnSync } from 'node:child_process';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const contenedor = 'supabase_db_fidelis-d6-isolated-test';
const carpeta = join(process.cwd(), 'supabase', 'tests');
let fallas = 0;

// La migracion 038 quita el EXECUTE por defecto a PUBLIC. Las funciones auxiliares de cada
// prueba (pg_temp.como, pg_temp.ok) lo necesitan, asi que se devuelve dentro de la transaccion
// de la prueba, que se revierte al final.
const PERMISO_AUXILIARES = 'BEGIN;\nALTER DEFAULT PRIVILEGES FOR ROLE postgres GRANT EXECUTE ON FUNCTIONS TO PUBLIC;';

for (const archivo of readdirSync(carpeta).filter((f) => f.endsWith('.sql')).sort()) {
  const sql = readFileSync(join(carpeta, archivo), 'utf8').replace(/^BEGIN;/m, PERMISO_AUXILIARES);
  const r = spawnSync(
    'docker',
    ['exec', '-i', contenedor, 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q'],
    { input: sql },
  );
  const salida = `${r.stdout ?? ''}${r.stderr ?? ''}`;
  if (r.status !== 0 || /FALLA|ERROR/.test(salida)) fallas += 1;
  const lineas = salida.split(/\r?\n/).filter((l) => /ok:|FALLA|ERROR/.test(l));
  console.log(`\n${archivo}`);
  for (const linea of lineas) console.log(`  ${linea.replace(/^(NOTICE|psql:[^:]*:\d+: ERROR):\s*/, '')}`);
}

if (fallas) {
  console.error(`\n${fallas} archivo(s) con fallas`);
  process.exit(1);
}

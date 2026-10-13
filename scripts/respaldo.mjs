// Respaldo de la base y de los archivos del expediente. El plan gratis de Supabase no trae
// respaldos descargables y los archivos de Storage no entran en un volcado de la base.
//
//   node scripts/respaldo.mjs
//
// Variables: SUPABASE_DB_URL (cadena de conexion directa de Postgres), SUPABASE_URL,
// SUPABASE_SERVICE_ROLE_KEY y RESPALDO_DIR (carpeta destino, fuera del repositorio).
// Deja en RESPALDO_DIR/AAAA-MM-DD_HHMM/: esquema.sql, datos.sql, la carpeta expedientes/
// y manifiesto.json con la huella SHA-256 de cada archivo. Programelo una vez al dia.
// Para restaurar: README, seccion Respaldos.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { createClient } from '@supabase/supabase-js';

const requerida = (nombre) => {
  const valor = process.env[nombre];
  if (!valor) throw new Error(`Falta la variable ${nombre}`);
  return valor;
};

const BUCKET = 'expedientes';
// Fecha y hora de Guatemala en el nombre de la carpeta (sv-SE da AAAA-MM-DD HH:MM).
const marca = new Date().toLocaleString('sv-SE', { timeZone: 'America/Guatemala' }).slice(0, 16).replace(' ', '_').replace(':', '');
const destino = join(requerida('RESPALDO_DIR'), marca);
mkdirSync(destino, { recursive: true });

function volcar(archivo, extra) {
  const r = spawnSync('npx', ['-y', 'supabase@latest', 'db', 'dump', '--db-url', requerida('SUPABASE_DB_URL'), '-f', join(destino, archivo), ...extra],
    { stdio: ['ignore', 'ignore', 'pipe'], shell: process.platform === 'win32' });
  if (r.status !== 0) throw new Error(`No se pudo volcar ${archivo}: ${String(r.stderr).slice(0, 300)}`);
}

async function listar(storage, carpeta = '') {
  const rutas = [];
  for (let desde = 0; ; desde += 1000) {
    const { data, error } = await storage.list(carpeta, { limit: 1000, offset: desde });
    if (error) throw error;
    for (const item of data) {
      const ruta = carpeta ? `${carpeta}/${item.name}` : item.name;
      if (item.id) rutas.push(ruta);
      else rutas.push(...(await listar(storage, ruta)));
    }
    if (data.length < 1000) return rutas;
  }
}

function huellas(carpeta) {
  const salida = {};
  for (const nombre of readdirSync(carpeta)) {
    const ruta = join(carpeta, nombre);
    if (statSync(ruta).isDirectory()) Object.assign(salida, huellas(ruta));
    else salida[relative(destino, ruta).replaceAll('\\', '/')] = createHash('sha256').update(readFileSync(ruta)).digest('hex');
  }
  return salida;
}

volcar('esquema.sql', []);
// Las tablas internas de Storage (vectores, iceberg, cargas multiparte) son del servicio y
// no se restauran: solo los buckets y los objetos.
const INTERNAS_STORAGE = ['buckets_analytics', 'buckets_vectors', 'iceberg_namespaces', 'iceberg_tables',
  's3_multipart_uploads', 's3_multipart_uploads_parts', 'vector_indexes'].map((t) => `storage.${t}`).join(',');
volcar('datos.sql', ['--data-only', '--use-copy', '--schema', 'public,auth,storage', '-x', INTERNAS_STORAGE]);

const supabase = createClient(requerida('SUPABASE_URL'), requerida('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
const storage = supabase.storage.from(BUCKET);
const rutas = await listar(storage);
for (const ruta of rutas) {
  const { data, error } = await storage.download(ruta);
  if (error) throw new Error(`No se pudo descargar ${ruta}: ${error.message}`);
  const archivo = join(destino, BUCKET, ruta);
  mkdirSync(dirname(archivo), { recursive: true });
  writeFileSync(archivo, Buffer.from(await data.arrayBuffer()));
}

const manifiesto = { creado: new Date().toISOString(), archivos_storage: rutas.length, huellas: huellas(destino) };
writeFileSync(join(destino, 'manifiesto.json'), JSON.stringify(manifiesto, null, 2));
console.log(`Respaldo en ${destino}: base (esquema y datos) y ${rutas.length} archivos del expediente.`);

import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL || '';
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY || '';

export const supabaseConfigurado = Boolean(url && anonKey && !/your-supabase|placeholder/.test(url));

// Modo reunion: el personal elige una marca y cada consulta lleva el encabezado x-d6-marca.
// Postgres (migracion 031) responde entonces exactamente como a esa marca. Se guarda por
// pestana para que un refresco en plena reunion no vuelva a mostrar todas las marcas.
const CLAVE_VISTA = 'd6-marca-en-vista';

function leerVista() {
  try {
    return JSON.parse(sessionStorage.getItem(CLAVE_VISTA) || 'null');
  } catch {
    return null;
  }
}

let marcaEnVista = leerVista();

export function marcaEnVistaActual() {
  return marcaEnVista;
}

export function fijarMarcaEnVista(marca) {
  marcaEnVista = marca || null;
  try {
    if (marcaEnVista) sessionStorage.setItem(CLAVE_VISTA, JSON.stringify(marcaEnVista));
    else sessionStorage.removeItem(CLAVE_VISTA);
  } catch {
    // Sin almacenamiento la vista dura hasta refrescar la pagina.
  }
}

function fetchConMarca(entrada, opciones = {}) {
  if (!marcaEnVista) return fetch(entrada, opciones);
  const encabezados = new Headers(opciones.headers || (entrada instanceof Request ? entrada.headers : undefined));
  encabezados.set('x-d6-marca', marcaEnVista.id);
  return fetch(entrada, { ...opciones, headers: encabezados });
}

// Sin credenciales no se crea cliente: la app muestra la pantalla de configuracion.
export const supabase = supabaseConfigurado
  ? createClient(url, anonKey, { auth: { persistSession: true, autoRefreshToken: true }, global: { fetch: fetchConMarca } })
  : null;

export const BUCKET_EXPEDIENTES = 'expedientes';

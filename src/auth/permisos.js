// Espejo de las politicas de la base de datos para decidir que se muestra.
// La autoridad es Postgres: esto solo evita botones que fallarian.
// Desde la migracion 044 la app es el portal del cliente. La marca pide altas, corrige su
// solicitud, pide bajas y reporta incumplimientos. El personal de Fidelis solo consulta: las
// decisiones viven en FISO. Administracion conserva usuarios, marcas y tarifas.

export const ROLES = Object.freeze({
  admin: 'Administración',
  suscripcion: 'Suscripción',
  comercial: 'Comercial',
  coordinacion_comercial: 'Comercialización',
  cobros: 'Cobros',
  contabilidad: 'Contabilidad',
  consulta: 'Consulta',
  beneficiario: 'Marca',
});

export const PERSONAL = ['admin', 'suscripcion', 'comercial', 'coordinacion_comercial', 'cobros', 'contabilidad', 'consulta'];
const TODOS = [...PERSONAL, 'beneficiario'];

const PERMISOS = {
  // Consulta
  verCartera: TODOS,
  verAltas: TODOS,
  verExpedientes: PERSONAL,
  verPagos: TODOS,
  verReclamos: TODOS,
  verDistribuidores: TODOS,
  verCondiciones: TODOS,
  verAfianzados: PERSONAL,
  verCuadre: PERSONAL,
  // Lo que hace la marca
  solicitarAlta: ['beneficiario'],
  // Corregir datos, subir documentos y compartir el enlace hasta que FISO emite.
  corregirAlta: ['beneficiario'],
  solicitarBaja: ['beneficiario'],
  reportarIncumplimiento: ['beneficiario'],
  // Administracion
  administrar: ['admin'],
};

// Lo que cambia un caso. El personal en modo reunion ve la app como la marca, pero no actua por ella.
const ACCIONES = new Set(['solicitarAlta', 'corregirAlta', 'solicitarBaja', 'reportarIncumplimiento']);

export function puede(roles, permiso, { personalReal = false } = {}) {
  const permitidos = PERMISOS[permiso];
  if (!permitidos) throw new Error(`Permiso desconocido: ${permiso}`);
  if (personalReal && ACCIONES.has(permiso)) return false;
  return roles.some((rol) => permitidos.includes(rol));
}

export function esPersonal(roles) {
  return roles.some((rol) => PERSONAL.includes(rol));
}

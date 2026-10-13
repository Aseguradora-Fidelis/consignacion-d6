// Invita usuarios y les asigna rol y marcas. Necesita la llave de servicio, por eso
// vive en el servidor. Solo responde a un administrador con sesion valida.
import { createClient } from 'npm:@supabase/supabase-js@2';

// En produccion APP_ORIGIN es obligatorio: sin el, el enlace de invitacion apuntaria a localhost.
const LOCAL = /127\.0\.0\.1|localhost|kong/.test(Deno.env.get('SUPABASE_URL') ?? '');
const ORIGEN = Deno.env.get('APP_ORIGIN') || (LOCAL ? 'http://127.0.0.1:5173' : '');
const ROLES = ['admin', 'suscripcion', 'comercial', 'coordinacion_comercial', 'cobros', 'contabilidad', 'consulta', 'beneficiario'];

function cabeceras(request: Request) {
  const origen = request.headers.get('Origin') || '';
  const permitidos = ORIGEN.split(',').map((o) => o.trim());
  return {
    'Access-Control-Allow-Origin': permitidos.includes(origen) ? origen : permitidos[0],
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    Vary: 'Origin',
  };
}

function respuesta(request: Request, cuerpo: unknown, status = 200) {
  return Response.json(cuerpo, { status, headers: cabeceras(request) });
}

Deno.serve(async (request) => {
  try {
    return await atender(request);
  } catch (error) {
    // El detalle queda en los logs de la funcion, no en la respuesta.
    console.error(error);
    return respuesta(request, { error: 'No se pudo completar la invitación. Intente de nuevo.' }, 500);
  }
});

async function atender(request: Request) {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cabeceras(request) });
  if (!ORIGEN) return respuesta(request, { error: 'Falta configurar APP_ORIGIN en la función.' }, 500);
  if (request.method !== 'POST') return respuesta(request, { error: 'Método no permitido' }, 405);

  const url = Deno.env.get('SUPABASE_URL') ?? '';
  const anon = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  const servicio = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

  const quien = createClient(url, anon, { global: { headers: { Authorization: request.headers.get('Authorization') ?? '' } } });
  const { data: sesion } = await quien.auth.getUser();
  if (!sesion?.user) return respuesta(request, { error: 'Ingrese de nuevo.' }, 401);
  const { data: esAdmin } = await quien.rpc('has_d6_role', { p_roles: ['admin'] });
  if (!esAdmin) return respuesta(request, { error: 'Solo Administración invita usuarios.' }, 403);

  let cuerpo: { accion?: string; email?: string; nombre?: string; roles?: string[]; grupos?: string[] };
  try {
    cuerpo = await request.json();
  } catch {
    return respuesta(request, { error: 'Solicitud inválida.' }, 400);
  }
  const email = String(cuerpo.email ?? '').trim().toLowerCase();
  const nombre = String(cuerpo.nombre ?? '').trim();
  const roles = (cuerpo.roles ?? []).filter((r) => ROLES.includes(r));
  const grupos = (cuerpo.grupos ?? []).filter((g) => /^[0-9a-f-]{36}$/.test(g));

  if (cuerpo.accion !== 'invitar') return respuesta(request, { error: 'Acción no soportada.' }, 400);
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return respuesta(request, { error: 'Correo inválido.' }, 400);
  if (!nombre) return respuesta(request, { error: 'Indique el nombre.' }, 400);
  if (!roles.length) return respuesta(request, { error: 'Asigne al menos un rol.' }, 400);
  if (roles.includes('beneficiario') && (roles.length > 1 || grupos.length !== 1)) {
    return respuesta(request, { error: 'Un usuario de marca tiene solo ese rol y exactamente una marca.' }, 400);
  }
  if (!roles.includes('beneficiario') && grupos.length) {
    return respuesta(request, { error: 'El personal de Fidelis no se asigna a una marca.' }, 400);
  }

  const admin = createClient(url, servicio, { auth: { persistSession: false } });
  const { data: invitado, error } = await admin.auth.admin.inviteUserByEmail(email, {
    data: { full_name: nombre },
    redirectTo: `${ORIGEN.split(',')[0].trim()}/ingresar`,
  });
  if (error) {
    if (/already been registered|already registered/i.test(error.message)) {
      return respuesta(request, { error: 'Ya existe un usuario con ese correo. Edite sus accesos en la lista.' }, 400);
    }
    console.error(error);
    return respuesta(request, { error: 'No se pudo enviar la invitación. Revise el correo e intente de nuevo.' }, 400);
  }

  const id = invitado.user.id;
  const r1 = await admin.from('user_role_assignments').insert(roles.map((role) => ({ user_id: id, role })));
  const r2 = grupos.length ? await admin.from('user_grupos').insert(grupos.map((grupo_id) => ({ user_id: id, grupo_id }))) : { error: null };
  if (r1.error || r2.error) {
    // Sin accesos el usuario quedaria a medias: se deshace la invitacion.
    console.error(r1.error ?? r2.error);
    await admin.from('user_role_assignments').delete().eq('user_id', id);
    await admin.from('user_grupos').delete().eq('user_id', id);
    await admin.auth.admin.deleteUser(id);
    return respuesta(request, { error: 'No se pudieron guardar los accesos. La invitación no se envió: intente de nuevo.' }, 500);
  }
  const bitacora = await admin.from('audit_log').insert({
    table_name: 'user_profiles', record_id: id, action: 'INSERT', origen: 'USUARIO',
    new_data: { email, roles, grupos, invitado_por: sesion.user.email }, performed_by: sesion.user.id,
    performed_by_email: sesion.user.email,
  });
  if (bitacora.error) console.error(bitacora.error);
  return respuesta(request, { id, email });
}

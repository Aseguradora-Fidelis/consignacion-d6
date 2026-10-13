import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { dato, rpc } from './cliente';

export function useUsuarios() {
  return useQuery({
    queryKey: ['usuarios'],
    queryFn: async () => {
      const [perfiles, roles, grupos] = await Promise.all([
        dato(supabase.from('user_profiles').select('id,email,full_name,created_at,activo,desactivado_at').order('full_name')),
        dato(supabase.from('user_role_assignments').select('user_id,role')),
        dato(supabase.from('user_grupos').select('user_id,grupo_id')),
      ]);
      return perfiles.map((p) => ({
        ...p,
        roles: roles.filter((r) => r.user_id === p.id).map((r) => r.role),
        grupos: grupos.filter((g) => g.user_id === p.id).map((g) => g.grupo_id),
      }));
    },
  });
}

// Crear usuarios necesita la llave de servicio: lo hace la Edge Function admin-usuarios.
export function useInvitarUsuario() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ email, nombre, roles, grupos }) => {
      const { data, error } = await supabase.functions.invoke('admin-usuarios', {
        body: { accion: 'invitar', email, nombre, roles, grupos },
      });
      if (error) {
        const detalle = await error.context?.json?.().catch(() => null);
        throw new Error(detalle?.error || error.message);
      }
      return data;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['usuarios'] }),
  });
}

// Roles y marcas se cambian directo: las politicas solo lo permiten a un admin.
export function useGuardarAccesos() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ userId, roles, grupos, rolesAntes, gruposAntes }) => {
      const quitarRoles = rolesAntes.filter((r) => !roles.includes(r));
      const ponerRoles = roles.filter((r) => !rolesAntes.includes(r));
      const quitarGrupos = gruposAntes.filter((g) => !grupos.includes(g));
      const ponerGrupos = grupos.filter((g) => !gruposAntes.includes(g));
      if (quitarRoles.length) await dato(supabase.from('user_role_assignments').delete().eq('user_id', userId).in('role', quitarRoles));
      if (ponerRoles.length) await dato(supabase.from('user_role_assignments').insert(ponerRoles.map((role) => ({ user_id: userId, role }))));
      if (quitarGrupos.length) await dato(supabase.from('user_grupos').delete().eq('user_id', userId).in('grupo_id', quitarGrupos));
      if (ponerGrupos.length) await dato(supabase.from('user_grupos').insert(ponerGrupos.map((grupo_id) => ({ user_id: userId, grupo_id }))));
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['usuarios'] }),
  });
}

// Un usuario se desactiva, no se borra: su nombre queda en la bitacora y en las decisiones (migracion 040).
export function useActivarUsuario() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ userId, activo }) => rpc('d6_desactivar_usuario', { p_user_id: userId, p_activo: activo }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['usuarios'] }),
  });
}

export function useAuditoria({ pagina = 1, porPagina = 30, tabla = '' }) {
  return useQuery({
    queryKey: ['auditoria', { pagina, porPagina, tabla }],
    queryFn: async () => {
      let q = supabase.from('audit_log')
        .select('id,table_name,record_id,action,old_data,new_data,created_at,performed_by_email,origen,autor:user_profiles(full_name,email)', { count: 'exact' })
        .order('created_at', { ascending: false });
      if (tabla) q = q.eq('table_name', tabla);
      const desde = (pagina - 1) * porPagina;
      return dato(q.range(desde, desde + porPagina - 1));
    },
  });
}

export function useReglasYTarifas() {
  return useQuery({
    queryKey: ['reglas-tarifas'],
    queryFn: async () => {
      const [marcas, reglas] = await Promise.all([
        dato(supabase.from('grupos_beneficiarios').select('id,codigo,nombre,tarifa_prima,codigo_regla_cobro').order('nombre')),
        dato(supabase.from('reglas_cobro_d6').select('*').order('codigo_marca')),
      ]);
      return { marcas, reglas };
    },
  });
}

export function useGuardarMarca() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, tarifa, regla }) => dato(
      supabase.from('grupos_beneficiarios').update({ tarifa_prima: Number(tarifa), codigo_regla_cobro: regla || null }).eq('id', id).select('id'),
    ),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['reglas-tarifas'] });
      qc.invalidateQueries({ queryKey: ['marcas'] });
    },
  });
}

// Beneficiarios que llegaron de Oracle sin marca: ninguna marca los ve hasta asignarlos.
export function useBeneficiariosSinMarca() {
  return useQuery({
    queryKey: ['beneficiarios-sin-marca'],
    queryFn: async () => {
      const [beneficiarios, relaciones, grupos] = await Promise.all([
        dato(supabase.from('beneficiarios').select('id,codigo_contacto,nombre').order('nombre')),
        dato(supabase.from('grupo_beneficiario_rel').select('beneficiario_id,grupo_id')),
        dato(supabase.from('grupos_beneficiarios').select('id,codigo')),
      ]);
      const general = grupos.find((g) => g.codigo === 'GRP-GENERAL')?.id;
      const conMarca = new Set(relaciones.filter((r) => r.grupo_id !== general).map((r) => r.beneficiario_id));
      return beneficiarios.filter((b) => !conMarca.has(b.id));
    },
  });
}

export function useAsignarBeneficiario() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ beneficiarioId, grupoId }) => dato(
      supabase.from('grupo_beneficiario_rel').insert({ beneficiario_id: beneficiarioId, grupo_id: grupoId }).select('id'),
    ),
    onSuccess: () => {
      for (const k of ['beneficiarios-sin-marca', 'marcas', 'cartera', 'cartera-por-marca']) qc.invalidateQueries({ queryKey: [k] });
    },
  });
}

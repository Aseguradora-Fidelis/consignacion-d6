import { keepPreviousData, useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { dato, rpc } from './cliente';

export function useAfianzados({ pagina = 1, porPagina = 30, buscar = '', nivel = '', alerta = '', soloActivos = true, orden = 'exposicion' }) {
  return useQuery({
    queryKey: ['perfil', 'lista', { pagina, porPagina, buscar, nivel, alerta, soloActivos, orden }],
    placeholderData: keepPreviousData,
    queryFn: async () => {
      let q = supabase.from('v_perfil_afianzados').select('*', { count: 'exact' });
      const texto = buscar.trim();
      if (texto) {
        if (/^\d+$/.test(texto)) q = q.eq('codigo', Number(texto));
        else q = q.ilike('nombre', `%${texto.replace(/[%_,()]/g, ' ')}%`);
      }
      if (soloActivos) q = q.gt('polizas_activas', 0);
      if (nivel) q = q.eq('nivel_riesgo', nivel);
      if (alerta) q = q.eq(alerta, true);
      q = q.order(orden, { ascending: false, nullsFirst: false }).order('nombre');
      const desde = (pagina - 1) * porPagina;
      return dato(q.range(desde, desde + porPagina - 1));
    },
  });
}

export function useAfianzado(clienteId) {
  return useQuery({
    queryKey: ['perfil', 'ficha', clienteId],
    enabled: Boolean(clienteId),
    queryFn: async () => {
      const [perfil, polizas, altas] = await Promise.all([
        dato(supabase.from('v_perfil_afianzados').select('*').eq('cliente_id', clienteId).maybeSingle()),
        dato(supabase.from('v_fianzas').select('id,fianza,endoso,beneficiario_nombre,marca_nombre,vigencia_desde,vigencia_hasta,fecha_emision,estado,monto_afianzado,monto_original,prima')
          .eq('cliente_id', clienteId).order('vigencia_hasta', { ascending: false })),
        dato(supabase.from('v_bandeja_altas').select('id,numero_solicitud,estado_operativo,monto_solicitado,beneficiario_nombre,created_at')
          .eq('cliente_id', clienteId).order('created_at', { ascending: false })),
      ]);
      return perfil ? { ...perfil, polizas, altas } : null;
    },
  });
}

export function useResumenRiesgo(habilitado = true) {
  return useQuery({
    queryKey: ['riesgo'],
    enabled: habilitado,
    queryFn: async () => (await rpc('d6_resumen_riesgo'))?.[0] || null,
  });
}

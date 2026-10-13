import { keepPreviousData, useMutation, useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { dato, rpc } from './cliente';

// Consultas de operacion: condiciones por marca, distribuidores, cuadre con FISO, vinculados e historial.

export function useCondicionesMarca() {
  return useQuery({
    queryKey: ['condiciones-marca'],
    staleTime: 5 * 60_000,
    queryFn: () => dato(
      supabase.from('condiciones_marca_d6')
        .select('*,grupo:grupos_beneficiarios(id,codigo,nombre,tarifa_prima)')
        .order('grupo_id'),
    ).then((filas) => filas.sort((a, b) => (a.grupo?.nombre || '').localeCompare(b.grupo?.nombre || ''))),
  });
}

export function useDistribuidores({ pagina = 1, porPagina = 30, buscar = '', marcaId = '', soloActivos = true, orden = 'monto_activo' }) {
  return useQuery({
    queryKey: ['distribuidores', { pagina, porPagina, buscar, marcaId, soloActivos, orden }],
    placeholderData: keepPreviousData,
    queryFn: async () => {
      let q = supabase.from('v_distribuidores').select('*', { count: 'exact' });
      const texto = buscar.trim();
      if (texto) {
        if (/^\d+$/.test(texto)) q = q.eq('cliente_codigo', Number(texto));
        else q = q.ilike('cliente_nombre', `%${texto.replace(/[%_,()]/g, ' ')}%`);
      }
      if (marcaId) q = q.eq('marca_id', marcaId);
      if (soloActivos) q = q.gt('fianzas_activas', 0);
      q = q.order(orden, { ascending: orden === 'proximo_vencimiento', nullsFirst: false }).order('cliente_nombre');
      const desde = (pagina - 1) * porPagina;
      return dato(q.range(desde, desde + porPagina - 1));
    },
  });
}

export function useVinculadosCliente(clienteId) {
  return useQuery({
    queryKey: ['vinculados', 'cliente', clienteId],
    enabled: Boolean(clienteId),
    queryFn: () => rpc('d6_vinculados_cliente', { p_cliente_id: clienteId }),
  });
}

export function useReferenciaAlta(solicitudId, habilitado = true) {
  return useQuery({
    queryKey: ['referencia-alta', solicitudId],
    enabled: Boolean(solicitudId) && habilitado,
    queryFn: () => rpc('d6_referencia_alta', { p_solicitud_id: solicitudId }),
  });
}

export function useCuadreFiso(habilitado = true) {
  return useQuery({
    queryKey: ['cuadre-fiso'],
    enabled: habilitado,
    queryFn: () => rpc('d6_cuadre_fiso'),
  });
}

export function useUltimaCargaOracle(habilitado = true) {
  return useQuery({
    queryKey: ['ultima-carga-oracle'],
    enabled: habilitado,
    queryFn: () => dato(
      supabase.from('oracle_sync_runs_d6').select('ejecutado_en,estado,filas_leidas')
        .eq('fuente', 'CARTERA_D6').order('ejecutado_en', { ascending: false }).limit(1),
    ).then((f) => f[0] || null),
  });
}

export function useHistorialAfianzado(clienteId) {
  return useQuery({
    queryKey: ['historial', clienteId],
    enabled: Boolean(clienteId),
    queryFn: () => rpc('d6_historial_afianzado', { p_cliente_id: clienteId }),
  });
}

export function useFianzasDelAfianzado(texto, marcaId) {
  const limpio = (texto || '').trim();
  return useQuery({
    queryKey: ['fianzas-para-vincular', limpio, marcaId],
    enabled: limpio.length >= 3,
    queryFn: async () => {
      let q = supabase.from('v_fianzas')
        .select('id,fianza,endoso,cliente_id,cliente_nombre,cliente_nit,monto_original,vigencia_hasta,estado,marca_id,beneficiario_codigo')
        .in('estado', ['VIGENTE', 'POR_RENOVAR', 'VENCIDA']);
      if (/^\d+$/.test(limpio)) q = q.eq('fianza', Number(limpio));
      else q = q.ilike('cliente_nombre', `%${limpio.replace(/[%_,()]/g, ' ')}%`);
      if (marcaId) q = q.eq('marca_id', marcaId);
      return dato(q.order('vigencia_hasta', { ascending: false }).limit(8));
    },
  });
}

// La marca indica que fianza se incrementa o renueva al pedir el alta.
export function useVincularFianzaAnterior() {
  return useMutation({
    mutationFn: ({ solicitudId, fianzaId, tipo }) =>
      rpc('d6_vincular_fianza_anterior', { p_solicitud_id: solicitudId, p_fianza_id: fianzaId, p_tipo: tipo }),
  });
}

// Marcas que el personal puede elegir para una reunion. No depende de la marca en pantalla.
export function useMarcasParaVista(habilitado = true) {
  return useQuery({
    queryKey: ['marcas-para-vista'],
    enabled: habilitado,
    staleTime: 10 * 60_000,
    queryFn: () => rpc('d6_marcas_para_vista'),
  });
}

import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { dato, rpc } from './cliente';

const COLUMNAS_LISTA =
  'id,fianza,endoso,cliente_id,cliente_nombre,cliente_codigo,beneficiario_nombre,beneficiario_codigo,marca_id,marca_nombre,' +
  'vigencia_desde,vigencia_hasta,estado,monto_afianzado,monto_original,prima,movimiento,fecha_cancelacion';

export function useCartera({ pagina = 1, porPagina = 25, buscar = '', estado = '', marcaId = '', movimiento = '', orden = 'vigencia_hasta' }) {
  return useQuery({
    queryKey: ['cartera', { pagina, porPagina, buscar, estado, marcaId, movimiento, orden }],
    placeholderData: keepPreviousData,
    queryFn: async () => {
      let q = supabase.from('v_fianzas').select(COLUMNAS_LISTA, { count: 'exact' });
      const texto = buscar.trim();
      if (texto) {
        if (/^\d+$/.test(texto)) q = q.or(`fianza.eq.${texto},cliente_codigo.eq.${texto}`);
        else q = q.ilike('cliente_nombre', `%${texto.replace(/[%_,()]/g, ' ')}%`);
      }
      if (estado === 'ACTIVAS') q = q.in('estado', ['VIGENTE', 'POR_RENOVAR', 'EN_BAJA']);
      else if (estado) q = q.eq('estado', estado);
      if (marcaId) q = q.eq('marca_id', marcaId);
      if (movimiento) q = q.eq('movimiento', movimiento);
      q = q.order(orden, { ascending: orden === 'vigencia_hasta' }).order('fianza', { ascending: false });
      const desde = (pagina - 1) * porPagina;
      return dato(q.range(desde, desde + porPagina - 1));
    },
  });
}

export function useFianza(id) {
  return useQuery({
    queryKey: ['fianza', id],
    enabled: Boolean(id),
    queryFn: async () => {
      const fianza = await dato(supabase.from('v_fianzas').select('*').eq('id', id).maybeSingle());
      if (!fianza) return null;
      const [bajas, historial] = await Promise.all([
        dato(supabase.from('solicitudes_baja').select('id,numero_solicitud,tipo_baja,motivo,estado,observaciones,created_at,fecha_efectiva').eq('fianza_id', id).order('created_at', { ascending: false })),
        dato(supabase.from('v_fianzas').select('id,fianza,endoso,vigencia_desde,vigencia_hasta,estado,monto_afianzado,beneficiario_nombre')
          .eq('cliente_id', fianza.cliente_id).neq('id', id).order('vigencia_hasta', { ascending: false }).limit(20)),
      ]);
      return { ...fianza, bajas, otrasPolizas: historial };
    },
  });
}

export function useResumenCartera(marcaId) {
  return useQuery({
    queryKey: ['resumen-cartera', marcaId || null],
    queryFn: () => rpc('d6_resumen_cartera', { p_marca_id: marcaId || null }),
  });
}

export function useCarteraPorMarca(habilitado = true) {
  return useQuery({
    queryKey: ['cartera-por-marca'],
    enabled: habilitado,
    queryFn: () => rpc('d6_cartera_por_marca'),
  });
}

export function usePorVencer(dias = 60, limite = 8) {
  return useQuery({
    queryKey: ['por-vencer', dias, limite],
    queryFn: () => dato(
      supabase.from('v_fianzas').select(COLUMNAS_LISTA)
        .eq('estado', 'POR_RENOVAR').order('vigencia_hasta').limit(limite),
    ),
  });
}

export function useMarcas() {
  return useQuery({
    queryKey: ['marcas'],
    staleTime: 10 * 60_000,
    queryFn: () => dato(
      supabase.from('grupos_beneficiarios')
        .select('id,codigo,nombre,tarifa_prima,codigo_regla_cobro,beneficiarios:grupo_beneficiario_rel(beneficiario:beneficiarios(id,codigo_contacto,nombre))')
        .neq('codigo', 'GRP-GENERAL').order('nombre'),
    ).then((filas) => filas.map((g) => ({ ...g, beneficiarios: (g.beneficiarios || []).map((b) => b.beneficiario).filter(Boolean) }))),
  });
}

export function useSolicitarBaja() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ fianzaId, tipo, motivo, fechaEfectiva, carta }) => {
      const [fila] = await rpc('d6_solicitar_baja', {
        p_fianza_id: fianzaId, p_tipo: tipo, p_motivo: motivo, p_fecha_efectiva: fechaEfectiva || null,
      });
      if (carta) {
        const ext = carta.type === 'application/pdf' ? 'pdf' : carta.type === 'image/png' ? 'png' : 'jpg';
        const ruta = `bajas/${fila.baja_id}/${crypto.randomUUID()}.${ext}`;
        const { error: e1 } = await supabase.storage.from('expedientes').upload(ruta, carta, { contentType: carta.type, upsert: false });
        if (e1) throw e1;
        const { data: { user } } = await supabase.auth.getUser();
        await dato(supabase.from('documentos').insert({
          solicitud_baja_id: fila.baja_id, categoria: 'CARTA_BAJA', nombre_archivo: carta.name, file_path: ruta,
          file_size: carta.size, mime_type: carta.type, origen: 'MARCA', subido_por: user.id,
        }));
      }
      return fila;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['bajas'] });
      qc.invalidateQueries({ queryKey: ['fianza'] });
      qc.invalidateQueries({ queryKey: ['cuadre-fiso'] });
    },
  });
}

// Vencimientos de fianzas activas en los proximos meses, agrupados por mes.
export function useVencimientos(meses = 6) {
  return useQuery({
    queryKey: ['vencimientos', meses],
    queryFn: async () => {
      const hoy = new Date();
      const hasta = new Date(hoy.getFullYear(), hoy.getMonth() + meses, 0);
      const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
      const filas = await dato(
        supabase.from('v_fianzas').select('vigencia_hasta,monto_afianzado')
          .in('estado', ['VIGENTE', 'POR_RENOVAR', 'EN_BAJA'])
          .gte('vigencia_hasta', iso(hoy)).lte('vigencia_hasta', iso(hasta)).limit(5000),
      );
      const grupos = [];
      for (let i = 0; i < meses; i += 1) {
        const d = new Date(hoy.getFullYear(), hoy.getMonth() + i, 1);
        grupos.push({ clave: iso(d).slice(0, 7), fecha: iso(d), polizas: 0, monto: 0 });
      }
      for (const f of filas) {
        const g = grupos.find((x) => x.clave === f.vigencia_hasta.slice(0, 7));
        if (g) {
          g.polizas += 1;
          g.monto += Number(f.monto_afianzado || 0);
        }
      }
      return grupos;
    },
  });
}

import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { dato } from './cliente';

// Pagos a Fidelis (migracion 044): lo que FISO le facturo a cada marca, por mes, con lo pagado y
// el saldo de la ultima carga de facturas. La app no genera ni envia estados de cuenta: el aviso
// de cobro lo manda FISO.
export function useCuentaMarca({ marcaId = '' } = {}) {
  return useQuery({
    queryKey: ['cuenta-marca', { marcaId }],
    queryFn: async () => {
      let q = supabase.from('v_cuenta_marca').select('*').order('periodo', { ascending: false }).order('marca_nombre').limit(600);
      if (marcaId) q = q.eq('marca_id', marcaId);
      return dato(q);
    },
  });
}

// Totales de la cuenta: saldo, vencido y la hora de la carga de FISO de donde sale el saldo.
export function resumirCuenta(filas) {
  const lista = filas || [];
  const suma = (f) => lista.filter(f).reduce((t, x) => t + Number(x.saldo || 0), 0);
  return {
    saldo: suma(() => true),
    vencido: suma((x) => x.estado === 'VENCIDO'),
    mesesVencidos: lista.filter((x) => x.estado === 'VENCIDO').length,
    porPagar: suma((x) => ['PENDIENTE', 'PARCIAL'].includes(x.estado)),
    mesesPorPagar: lista.filter((x) => ['PENDIENTE', 'PARCIAL'].includes(x.estado)).length,
    saldoAl: lista.map((x) => x.saldo_fiso_al).filter(Boolean).sort().at(-1) || null,
  };
}

function finDeMes(periodo) {
  const [a, m] = periodo.split('-').map(Number);
  const d = new Date(a, m, 0);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

// Un mes de una marca: su fila de la cuenta y cada factura o nota de cobro de FISO.
export function useMesCuenta(marcaId, periodo) {
  return useQuery({
    queryKey: ['mes-cuenta', marcaId, periodo],
    enabled: Boolean(marcaId && periodo),
    queryFn: async () => {
      const [resumen, rel] = await Promise.all([
        dato(supabase.from('v_cuenta_marca').select('*').eq('marca_id', marcaId).eq('periodo', periodo).maybeSingle()),
        dato(supabase.from('grupo_beneficiario_rel').select('beneficiario_id').eq('grupo_id', marcaId)),
      ]);
      const beneficiarios = (rel || []).map((r) => r.beneficiario_id);
      const facturas = beneficiarios.length
        ? await dato(supabase.from('facturas_fiso_d6')
          .select('correlativo_cobro,serie,factura,fianza,endoso,fianza_id,fecha_emision,prima,derechos,iva,otros,total,saldo,fecha_pago,'
            + 'poliza:fianzas(id,cliente:clientes(nombre)),beneficiario:beneficiarios(nombre)')
          .in('beneficiario_id', beneficiarios)
          .is('fecha_anulacion', null)
          .gte('fecha_emision', periodo)
          .lte('fecha_emision', finDeMes(periodo))
          .order('fecha_emision')
          .order('correlativo_cobro'))
        : [];
      return { resumen, facturas };
    },
  });
}

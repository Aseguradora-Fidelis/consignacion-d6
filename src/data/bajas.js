import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { dato } from './cliente';

// Bajas que pidieron las marcas. Quedan procesadas cuando FISO cancela la fianza.
// procesadas: true solo las procesadas, false solo las pendientes en FISO, null todas.
export function useBajas({ procesadas = null } = {}) {
  return useQuery({
    queryKey: ['bajas', { procesadas }],
    queryFn: async () => {
      const filas = await dato(supabase
        .from('solicitudes_baja')
        .select('id,numero_solicitud,tipo_baja,motivo,estado,observaciones,created_at,updated_at,fecha_efectiva,' +
          'fianza:fianzas(id,fianza,endoso,monto_afianzado,vigencia_hasta,operational_status,fecha_cancelacion,' +
          'cliente:clientes(nombre),beneficiario:beneficiarios(nombre)),' +
          'documentos(id,nombre_archivo,file_path,categoria)')
        .order('created_at', { ascending: false })
        .limit(300));
      if (procesadas === null) return filas;
      return filas.filter((b) => ['CANCELADA', 'ANULADA'].includes(b.fianza?.operational_status) === procesadas);
    },
  });
}

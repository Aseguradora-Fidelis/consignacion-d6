import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { BUCKET_EXPEDIENTES, supabase } from '../lib/supabase';
import { dato, rpc } from './cliente';

export function useReclamos({ estado = '', clienteId = '' } = {}) {
  return useQuery({
    queryKey: ['reclamos', { estado, clienteId }],
    queryFn: async () => {
      let q = supabase.from('v_reclamos').select('*').order('created_at', { ascending: false }).limit(300);
      if (estado === 'ABIERTOS') q = q.not('estado', 'in', '(IMPROCEDENTE,CERRADO,DESISTIDO,RECUPERADO)');
      else if (estado === 'CERRADOS') q = q.in('estado', ['IMPROCEDENTE', 'CERRADO', 'DESISTIDO', 'RECUPERADO']);
      else if (estado) q = q.eq('estado', estado);
      if (clienteId) q = q.eq('cliente_id', clienteId);
      return dato(q);
    },
  });
}

export function useReclamo(id) {
  return useQuery({
    queryKey: ['reclamo', id],
    enabled: Boolean(id),
    queryFn: async () => {
      const [reclamo, movimientos, documentos] = await Promise.all([
        dato(supabase.from('v_reclamos').select('*').eq('id', id).maybeSingle()),
        dato(supabase.from('reclamo_movimientos_d6').select('*, autor:user_profiles(full_name)').eq('reclamo_id', id).order('created_at', { ascending: false })),
        dato(supabase.from('documentos').select('*').eq('reclamo_id', id).order('created_at')),
      ]);
      return reclamo ? { ...reclamo, movimientos, documentos } : null;
    },
  });
}

function invalidar(qc, id) {
  qc.invalidateQueries({ queryKey: ['reclamos'] });
  if (id) qc.invalidateQueries({ queryKey: ['reclamo', id] });
  qc.invalidateQueries({ queryKey: ['perfil'] });
  qc.invalidateQueries({ queryKey: ['riesgo'] });
}

async function subirEvidencia(reclamoId, archivo) {
  const ext = archivo.type === 'application/pdf' ? 'pdf' : archivo.type === 'image/png' ? 'png' : 'jpg';
  const ruta = `reclamos/${reclamoId}/${crypto.randomUUID()}.${ext}`;
  const { error } = await supabase.storage.from(BUCKET_EXPEDIENTES).upload(ruta, archivo, { contentType: archivo.type, upsert: false });
  if (error) throw error;
  const { data: { user } } = await supabase.auth.getUser();
  await dato(supabase.from('documentos').insert({
    reclamo_id: reclamoId, categoria: 'OTRO', nombre_archivo: archivo.name, file_path: ruta,
    file_size: archivo.size, mime_type: archivo.type, origen: 'MARCA', subido_por: user.id,
  }));
}

// La marca reporta el incumplimiento con su carta o evidencia.
export function useReportarIncumplimiento() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ fianzaId, tipo, fecha, monto, descripcion, unidades, presentar, archivos = [] }) => {
      const [fila] = await rpc('d6_reportar_incumplimiento', {
        p_fianza_id: fianzaId, p_tipo: tipo, p_fecha: fecha, p_monto: Number(monto), p_descripcion: descripcion,
        p_unidades: unidades ? Number(unidades) : null, p_presentar: presentar,
      });
      for (const a of archivos) await subirEvidencia(fila.reclamo_id, a);
      return fila;
    },
    onSuccess: () => invalidar(qc),
  });
}

// La marca agrega un mensaje al seguimiento de su reclamo.
export function useComentarReclamo(id) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ comentario }) => rpc('d6_comentar_reclamo', { p_reclamo_id: id, p_comentario: comentario, p_interno: false }),
    onSuccess: () => invalidar(qc, id),
  });
}

export function useSubirEvidencia(id) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (archivo) => subirEvidencia(id, archivo),
    onSuccess: () => invalidar(qc, id),
  });
}

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { BUCKET_EXPEDIENTES, supabase } from '../lib/supabase';
import { rpc } from './cliente';

// El portal no tiene sesion: todo pasa por RPC con el token del enlace.
export function useContextoPortal(token) {
  return useQuery({
    queryKey: ['portal', token],
    enabled: Boolean(token),
    retry: false,
    refetchOnWindowFocus: false,
    queryFn: () => rpc('portal_ive_contexto', { p_token: token }),
  });
}

export async function guardarBorrador(token, datos) {
  await rpc('portal_ive_guardar_borrador', { p_token: token, p_datos: datos });
}

export function useSubirDocumentoPortal(token) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ archivo, categoria }) => {
      const reserva = await rpc('portal_ive_preparar_carga', {
        p_token: token,
        p_categoria: categoria,
        p_nombre_archivo: archivo.name,
        p_mime: archivo.type,
        p_tamano: archivo.size,
      });
      const { error } = await supabase.storage.from(BUCKET_EXPEDIENTES).upload(reserva.path, archivo, {
        contentType: archivo.type,
        upsert: false,
      });
      if (error) throw error;
      await rpc('portal_ive_confirmar_carga', { p_token: token, p_documento_id: reserva.documento_id });
      return reserva;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['portal', token] }),
  });
}

export function useQuitarDocumentoPortal(token) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (documentoId) => rpc('portal_ive_quitar_documento', { p_token: token, p_documento_id: documentoId }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['portal', token] }),
  });
}

export function useEnviarExpediente(token) {
  return useMutation({
    mutationFn: (datos) => rpc('completar_ive_invitacion', { p_token: token, p_datos: datos }),
  });
}

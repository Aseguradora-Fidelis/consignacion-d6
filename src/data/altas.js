import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { BUCKET_EXPEDIENTES, supabase } from '../lib/supabase';
import { dato, queryClient, rpc } from './cliente';
import { prellenadoDesdeMarca } from '../domain/formularioIve';

// Personal de Fidelis: bandeja de consulta. Marca: vista sin datos IVE.
export function useAltas({ esPersonal, estados = null, buscar = '' }) {
  return useQuery({
    queryKey: ['altas', { esPersonal, estados, buscar }],
    queryFn: async () => {
      const vista = esPersonal ? 'v_bandeja_altas' : 'v_solicitudes_alta_marca';
      let q = supabase.from(vista).select('*').order('created_at', { ascending: false }).limit(500);
      if (estados?.length) q = q.in('estado_operativo', estados);
      const texto = buscar.trim();
      if (texto) q = q.or(`afianzado_nombre.ilike.%${texto.replace(/[%_,()]/g, ' ')}%,numero_solicitud.ilike.%${texto.replace(/[%_,()]/g, ' ')}%`);
      return dato(q);
    },
  });
}

// Lo que ve la marca de una solicitud. Emitida, trae vigencia y contrato de la fianza de FISO.
export function useAltaMarca(id) {
  return useQuery({
    queryKey: ['alta-marca', id],
    enabled: Boolean(id),
    queryFn: async () => {
      const alta = await dato(supabase.from('v_solicitudes_alta_marca').select('*').eq('id', id).maybeSingle());
      if (!alta?.fianza_emitida) return alta;
      const fianza = await dato(supabase.from('v_fianzas')
        .select('id,fianza,endoso,vigencia_desde,vigencia_hasta,contrato_numero,contrato_fecha,monto_original,fecha_emision')
        .eq('fianza', alta.fianza_emitida).eq('beneficiario_id', alta.beneficiario_id)
        .order('endoso', { ascending: false }).limit(1));
      return { ...alta, fianza: fianza[0] || null };
    },
  });
}

// El expediente completo para el personal de Fidelis, solo de consulta.
export function useExpediente(id) {
  return useQuery({
    queryKey: ['expediente', id],
    enabled: Boolean(id),
    queryFn: async () => {
      const [solicitud, bandeja, documentos, revisiones, requisitos] = await Promise.all([
        dato(supabase.from('solicitudes_alta').select('*').eq('id', id).maybeSingle()),
        dato(supabase.from('v_bandeja_altas').select('*').eq('id', id).maybeSingle()),
        dato(supabase.from('documentos').select('*').eq('solicitud_alta_id', id).eq('carga_pendiente', false).order('created_at')),
        dato(supabase.from('solicitud_revisiones').select('*, autor:user_profiles(full_name)').eq('solicitud_alta_id', id).order('created_at', { ascending: false })),
        dato(supabase.from('ive_requisitos_d6').select('*').eq('activo', true).order('orden')),
      ]);
      if (!solicitud) return null;
      const [beneficiario, grupo, fianzaAnterior, fianzaEmitida] = await Promise.all([
        dato(supabase.from('beneficiarios').select('id,codigo_contacto,nombre').eq('id', solicitud.beneficiario_id).maybeSingle()),
        dato(supabase.from('grupo_beneficiario_rel').select('grupo:grupos_beneficiarios(id,nombre,codigo)').eq('beneficiario_id', solicitud.beneficiario_id)),
        solicitud.fianza_anterior_id
          ? dato(supabase.from('v_fianzas').select('id,fianza,endoso,monto_original,contrato_numero,contrato_fecha,vigencia_hasta').eq('id', solicitud.fianza_anterior_id).maybeSingle())
          : null,
        solicitud.fianza_emitida_id
          ? dato(supabase.from('v_fianzas').select('id,fianza,endoso,monto_original,vigencia_desde,vigencia_hasta,contrato_numero,fecha_emision').eq('id', solicitud.fianza_emitida_id).maybeSingle())
          : null,
      ]);
      const marca = (grupo || []).map((g) => g.grupo).find((g) => g && g.codigo !== 'GRP-GENERAL') || null;
      return {
        solicitud,
        bandeja,
        documentos,
        revisiones,
        requisitos: requisitos.filter((r) => r.tipo_persona === solicitud.tipo_persona),
        beneficiario,
        marca,
        fianzaAnterior,
        fianzaEmitida,
      };
    },
  });
}

function invalidarAltas(qc, id) {
  qc.invalidateQueries({ queryKey: ['altas'] });
  qc.invalidateQueries({ queryKey: ['alta-marca'] });
  if (id) qc.invalidateQueries({ queryKey: ['expediente', id] });
  qc.invalidateQueries({ queryKey: ['tablero'] });
}

export function useSolicitarAlta() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (d) => {
      const [fila] = await rpc('d6_solicitar_alta', {
        p_beneficiario_codigo: Number(d.beneficiarioCodigo),
        p_cliente_nombre: d.nombre,
        p_cliente_email: d.correo,
        p_monto: Number(d.monto),
        p_tipo_persona: d.tipoPersona,
        p_cliente_nit: d.nit || null,
        p_cliente_telefono: d.telefono || null,
        p_resolucion_numero: d.resolucionNumero || null,
        p_resolucion_fecha: d.resolucionFecha || null,
        p_resolucion_monto: d.resolucionMonto ? Number(d.resolucionMonto) : null,
        p_resolucion_plazo_dias: d.resolucionPlazo ? Number(d.resolucionPlazo) : null,
        p_observaciones: d.observaciones || null,
      });
      // Lo que la marca ya escribio llega precargado al formulario del distribuidor.
      const prellenado = prellenadoDesdeMarca(d);
      if (Object.keys(prellenado).length) await rpc('d6_alta_guardar_borrador', { p_solicitud_id: fila.solicitud_id, p_cambios: prellenado });
      return fila;
    },
    onSuccess: () => invalidarAltas(qc),
  });
}

export function useReenviarEnlace() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, correo, telefono }) => {
      const [fila] = await rpc('crear_invitacion_ive', {
        p_solicitud_id: id, p_destinatario_email: correo || null, p_horas: 168, p_destinatario_telefono: telefono || null,
      });
      return fila;
    },
    onSuccess: (_, { id }) => invalidarAltas(qc, id),
  });
}

async function urlFirmada(filePath, opciones) {
  const { data, error } = await supabase.storage.from(BUCKET_EXPEDIENTES).createSignedUrl(filePath, 300, opciones);
  if (error) throw error;
  return data.signedUrl;
}

export async function abrirDocumento(filePath) {
  window.open(await urlFirmada(filePath), '_blank', 'noopener');
}

// Descarga cada documento del expediente con su nombre, uno detras de otro.
export async function descargarDocumentos(documentos, prefijo = '') {
  for (const d of documentos) {
    const nombreArchivo = `${prefijo}${d.nombre_archivo || d.file_path.split('/').pop()}`;
    const url = await urlFirmada(d.file_path, { download: nombreArchivo });
    const a = document.createElement('a');
    a.href = url;
    a.rel = 'noopener';
    a.download = nombreArchivo;
    document.body.appendChild(a);
    a.click();
    a.remove();
    // Los navegadores frenan varias descargas seguidas sin una pausa.
    await new Promise((r) => setTimeout(r, 400));
  }
}

export function enlacePortal(token) {
  return `${window.location.origin}/portal?t=${encodeURIComponent(token)}`;
}

// ---------------------------------------------------------------------------
// Expediente compartido: la marca adelanta y corrige datos y documentos hasta que FISO emite.

export function useAltaCompartida(id, habilitado = true) {
  return useQuery({
    queryKey: ['alta-compartida', id],
    enabled: Boolean(id) && habilitado,
    refetchOnWindowFocus: true,
    queryFn: () => rpc('d6_alta_compartida', { p_solicitud_id: id }),
  });
}

// Guarda solo lo que cambio. Despues del envio edita el formulario enviado: el servidor rechaza
// el cambio si deja vacio un dato obligatorio. Cada cambio queda en el registro.
export async function guardarBorradorAlta(id, cambios) {
  await rpc('d6_alta_guardar_borrador', { p_solicitud_id: id, p_cambios: cambios });
  for (const clave of ['alta-compartida', 'alta-cambios', 'expediente']) {
    queryClient.invalidateQueries({ queryKey: [clave, id], refetchType: clave === 'alta-compartida' ? 'none' : 'active' });
  }
}

// Registro de cambios de la marca a los datos del formulario, lo mas reciente primero.
export function useCambiosAlta(id, habilitado = true) {
  return useQuery({
    queryKey: ['alta-cambios', id],
    enabled: Boolean(id) && habilitado,
    queryFn: () => rpc('d6_alta_cambios', { p_solicitud_id: id }),
  });
}

export function useSubirDocumentoAlta(id) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ archivo, categoria }) => {
      const reserva = await rpc('d6_alta_preparar_carga', {
        p_solicitud_id: id, p_categoria: categoria, p_nombre_archivo: archivo.name, p_mime: archivo.type, p_tamano: archivo.size,
      });
      const { error } = await supabase.storage.from(BUCKET_EXPEDIENTES).upload(reserva.path, archivo, { contentType: archivo.type, upsert: false });
      if (error) throw error;
      await rpc('d6_alta_confirmar_carga', { p_documento_id: reserva.documento_id });
      return reserva;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['alta-compartida', id] });
      qc.invalidateQueries({ queryKey: ['alta-marca', id] });
      qc.invalidateQueries({ queryKey: ['expediente', id] });
    },
  });
}

export function useQuitarDocumentoAlta(id) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (documentoId) => rpc('d6_alta_quitar_documento', { p_documento_id: documentoId }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['alta-compartida', id] });
      qc.invalidateQueries({ queryKey: ['alta-marca', id] });
    },
  });
}

// Documentos que se pediran segun el tipo de cliente. La marca los ve antes de pedir el alta.
export function useRequisitos(tipoPersona) {
  return useQuery({
    queryKey: ['requisitos', tipoPersona],
    staleTime: 10 * 60_000,
    queryFn: () => dato(supabase.from('ive_requisitos_d6')
      .select('categoria,nombre,ayuda,obligatorio,responsable,orden')
      .eq('activo', true).eq('tipo_persona', tipoPersona).not('categoria', 'in', '(IVE_ASS_01,IVE_ASS_02)').order('orden')),
  });
}

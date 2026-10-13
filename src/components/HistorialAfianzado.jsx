import { Link } from 'react-router-dom';
import { FileText, Gavel, Mail, MessageCircle, MessagesSquare, Phone, ShieldCheck, StickyNote, UserCheck, FileMinus2 } from 'lucide-react';
import { Cargando, ErrorCarga } from './ui';
import { useHistorialAfianzado } from '../data/operacion';
import { fecha, fechaHora } from '../lib/format';

// Altas, bajas, reclamos y emisiones del afianzado en orden. Solo de consulta: las
// comunicaciones registradas antes de la migracion 044 se siguen viendo.
const CANALES = {
  CORREO: Mail,
  LLAMADA: Phone,
  WHATSAPP: MessageCircle,
  REUNION: MessagesSquare,
  NOTA: StickyNote,
};
const TIPO_ICONO = { ALTA: FileText, BAJA: FileMinus2, RECLAMO: Gavel, EMISION: ShieldCheck };

export default function HistorialAfianzado({ clienteId }) {
  const { data, isLoading, error, refetch } = useHistorialAfianzado(clienteId);
  if (isLoading) return <Cargando />;
  if (error) return <ErrorCarga error={error} reintentar={refetch} />;
  if (!data?.length) return <p className="al-dia">Todavía no hay movimientos.</p>;
  return (
    <ul className="tareas">
      {data.slice(0, 40).map((h, i) => {
        const canal = h.tipo.startsWith('COMUNICACION:') ? h.tipo.split(':')[1] : null;
        const Icono = canal ? CANALES[canal] || UserCheck : TIPO_ICONO[h.tipo] || FileText;
        const contenido = (
          <>
            <Icono size={18} aria-hidden="true" style={{ flexShrink: 0, color: canal ? 'var(--verde-oscuro)' : 'var(--texto-3)' }} />
            <span className="tarea-texto">
              <strong title={h.titulo}>{h.titulo}</strong>
              <span className="sub" title={h.detalle || ''}>{h.tipo === 'EMISION' ? fecha(h.ocurrido_at) : fechaHora(h.ocurrido_at)}{h.autor ? ` · ${h.autor}` : ''}{h.detalle ? ` · ${h.detalle}` : ''}</span>
            </span>
          </>
        );
        return (
          <li key={`${h.ocurrido_at}-${i}`}>
            {h.enlace ? <Link className="tarea" to={h.enlace}>{contenido}</Link> : <div className="tarea">{contenido}</div>}
          </li>
        );
      })}
    </ul>
  );
}

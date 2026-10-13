import { Link } from 'react-router-dom';
import { CheckCircle2, Circle, PencilLine } from 'lucide-react';
import { useAuth } from '../../auth/AuthProvider';
import { Cargando } from '../ui';
import { useAltaCompartida } from '../../data/altas';
import { datosIniciales, pendientesPorSeccion } from '../../domain/formularioIve';
import { hace } from '../../lib/format';

const QUIEN = { MARCA: 'usted', FIDELIS: 'Fidelis', AFIANZADO: 'el distribuidor' };

// Documentos retirados o reemplazados por quien los subio no cuentan.
const vigentes = (r) => r.documentos.filter((d) => d.estado !== 'RECHAZADO');

// Lo que ya se lleno y se subio, para que la marca de seguimiento sin llamar al distribuidor.
export default function AvanceExpediente({ id, esMarca }) {
  const { puede } = useAuth();
  const { data: a, isLoading } = useAltaCompartida(id);
  if (isLoading) return <Cargando />;
  if (!a) return null;
  const partes = a.borrador ? pendientesPorSeccion(a.tipo_persona, datosIniciales(a.tipo_persona, a.borrador)) : [];
  const docsListos = a.requisitos.filter((r) => vigentes(r).length).length;
  const partesListas = partes.filter((p) => !p.faltan.length).length;

  return (
    <section className="stack">
      <div className="row-between">
        <h2 style={{ fontSize: 'var(--t-lg)' }}>Avance de la solicitud</h2>
        {puede('corregirAlta') && (a.editable || a.recibe_documentos) && (
          <Link className="btn btn-primario btn-sm" to={`/altas/${id}/completar`}>
            <PencilLine size={16} aria-hidden="true" />
            {' '}{!a.editable ? 'Subir documentos pendientes'
              : a.enviado ? 'Corregir datos y documentos'
                : 'Adelantar datos y documentos'}
          </Link>
        )}
      </div>
      {a.enviado ? (
        <div className="stack" style={{ gap: '0.35rem' }}>
          <p className="small muted">
            El distribuidor ya envió su formulario. Documentos: <strong>{docsListos} de {a.requisitos.length}</strong>.
          </p>
          {a.editable && puede('corregirAlta') && (
            <p className="small">Puede corregir los datos y subir documentos hasta que la fianza se emita en FISO. Cada cambio queda registrado con su nombre.</p>
          )}
        </div>
      ) : (
        <div className="avance-partes">
          <p className="small">
            Formulario: <strong>{partesListas} de {partes.length} partes completas</strong> · Documentos: <strong>{docsListos} de {a.requisitos.length}</strong>
          </p>
          <ul className="avance-lista">
            {partes.map((p) => (
              <li key={p.titulo}>
                {p.faltan.length
                  ? <Circle size={16} aria-hidden="true" style={{ color: 'var(--gris-500)' }} />
                  : <CheckCircle2 size={16} aria-hidden="true" style={{ color: 'var(--ok)' }} />}
                <span>{p.titulo}</span>
                {p.faltan.length > 0 && <span className="small muted">falta{p.faltan.length > 1 ? 'n' : ''} {p.faltan.length}</span>}
              </li>
            ))}
          </ul>
        </div>
      )}
      <ul className="avance-lista">
        {a.requisitos.map((r) => {
          const docs = vigentes(r);
          return (
            <li key={r.categoria}>
              {docs.length
                ? <CheckCircle2 size={16} aria-hidden="true" style={{ color: 'var(--ok)' }} />
                : <Circle size={16} aria-hidden="true" style={{ color: 'var(--gris-500)' }} />}
              <span>{r.nombre}{!r.obligatorio && <span className="muted"> (si aplica)</span>}</span>
              {docs.length > 0 ? (
                <span className="small muted">
                  subido por {QUIEN[docs[docs.length - 1].origen] || 'el distribuidor'} {hace(docs[docs.length - 1].subido)}
                </span>
              ) : (
                <span className="small muted">{r.responsable === 'MARCA' ? (esMarca ? 'le toca a usted' : 'lo sube la marca') : 'pendiente'}</span>
              )}
            </li>
          );
        })}
      </ul>
    </section>
  );
}

import { Link } from 'react-router-dom';
import { AlertTriangle, CheckCircle2, XCircle } from 'lucide-react';
import { Cargando, ErrorCarga } from './ui';
import { useReferenciaAlta } from '../data/operacion';
import { leerReferencia } from '../domain/referenciaDistribuidor';
import { nombre, q } from '../lib/format';

const ICONO = { ok: CheckCircle2, atencion: AlertTriangle, critico: XCircle };

export function TablaVinculados({ vinculados }) {
  if (!vinculados?.length) return <p className="muted small">No se encontraron afianzados con el mismo teléfono, dirección, patente o apellidos.</p>;
  return (
    <div className="tabla-marco">
      <table className="tabla">
        <thead><tr><th>Afianzado</th><th>Coincide en</th><th>Marcas</th><th className="derecha">Exposición</th></tr></thead>
        <tbody>
          {vinculados.map((v) => (
            <tr key={v.cliente_id}>
              <td><Link className="principal-celda" to={`/afianzados/${v.cliente_id}`}>{nombre(v.nombre)}</Link></td>
              <td className="small">{v.motivo}</td>
              <td className="small">{v.marcas || <span className="muted">Sin fianza activa</span>}</td>
              <td className="derecha num">{q(v.exposicion)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// Lo que Fidelis ya sabe del distribuidor, para consultar junto al expediente.
export default function ReferenciaDistribuidor({ solicitudId }) {
  const { data, isLoading, error, refetch } = useReferenciaAlta(solicitudId);
  if (isLoading) return <Cargando texto="Leyendo la referencia" />;
  if (error) return <ErrorCarga error={error} reintentar={refetch} />;
  const r = leerReferencia(data);
  if (!r) return null;
  const marca = data.marca || {};

  return (
    <section className="stack">
      <h3>Referencia del distribuidor</h3>
      <dl className="comparativa">
        <div><dt>Pide</dt><dd>{q(data.monto_solicitado)}</dd></div>
        <div><dt>{data.tipo_solicitud === 'NUEVA' ? 'Maneja hoy con la marca' : 'Fianza que cambia'}</dt><dd>{r.base ? q(r.base) : 'Cliente nuevo'}</dd></div>
        <div><dt>Total con todas las marcas</dt><dd>{q(data.exposicion_total)}</dd></div>
        {marca.mediana != null && <div><dt>El 50 % de sus {marca.distribuidores} distribuidores maneja hasta</dt><dd>{q(marca.mediana)}</dd></div>}
        {marca.p90 != null && <div><dt>El 90 % maneja hasta</dt><dd>{q(marca.p90)}</dd></div>}
      </dl>
      {r.lineas.length > 0 && (
        <ul className="referencia-lineas">
          {r.lineas.map((l) => {
            const Icono = ICONO[l.tono];
            return <li key={l.texto}><Icono size={18} aria-hidden="true" className={`estado-${l.tono}`} />{l.texto}</li>;
          })}
        </ul>
      )}
      {r.contexto && <p className="small muted">{r.contexto} Fuente: FISO y reclamos de la app.</p>}
      {data.vinculados?.length > 0 && (
        <div className="stack" style={{ gap: '0.5rem' }}>
          <h3>Posibles vinculados</h3>
          <TablaVinculados vinculados={data.vinculados} />
        </div>
      )}
    </section>
  );
}

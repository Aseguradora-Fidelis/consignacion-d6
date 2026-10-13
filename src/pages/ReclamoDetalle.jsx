import { useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, ExternalLink, FileUp, Lock } from 'lucide-react';
import { useAuth } from '../auth/AuthProvider';
import { Aviso, Cargando, Datos, Encabezado, ErrorCarga, Estado, Panel, Vacio } from '../components/ui';
import { useToast } from '../components/ui/Toasts';
import { abrirDocumento } from '../data/altas';
import { useComentarReclamo, useReclamo, useSubirEvidencia } from '../data/reclamos';
import { ESTADO_RECLAMO, TIPO_RECLAMO } from '../domain/estados';
import { fecha, fechaHora, nombre, q } from '../lib/format';

const CERRADOS = ['CERRADO', 'DESISTIDO', 'IMPROCEDENTE', 'RECUPERADO'];

// La marca reporta el incumplimiento con su evidencia y deja mensajes. El personal de Fidelis
// lo consulta: el reclamo no se mueve desde la app.
export default function ReclamoDetalle() {
  const { id } = useParams();
  const { usuario, puede } = useAuth();
  const { data: r, isLoading, error, refetch } = useReclamo(id);
  const comentar = useComentarReclamo(id);
  const subir = useSubirEvidencia(id);
  const toast = useToast();
  const [nota, setNota] = useState('');
  const volver = <Link to="/reclamos" className="volver"><ArrowLeft size={16} aria-hidden="true" /> Reclamos</Link>;

  if (isLoading) return <Cargando />;
  if (error) return <>{volver}<ErrorCarga error={error} reintentar={refetch} /></>;
  if (!r) return <>{volver}<Vacio titulo="No encontramos este reclamo" /></>;

  const esLaMarca = puede('reportarIncumplimiento');
  const abierto = !CERRADOS.includes(r.estado);
  const porRecuperar = Number(r.monto_pagado || 0) - Number(r.monto_recuperado || 0);

  return (
    <div>
      <Encabezado volver={volver} titulo={`Reclamo ${r.numero}`}
        descripcion={`${nombre(r.afianzado_nombre)} · fianza ${r.fianza} · ${nombre(r.beneficiario_nombre)}`} />
      <div className="tablero" style={{ marginTop: 0 }}>
        <div className="c-8 columna">
          <Panel titulo="Incumplimiento" accion={<Estado mapa={ESTADO_RECLAMO} valor={r.estado} />}>
            <Datos items={[
              ['Qué pasó', TIPO_RECLAMO[r.tipo]],
              ['Desde', fecha(r.fecha_incumplimiento)],
              ['Monto reclamado', <span key="reclamado" className="num">{q(r.monto_reclamado)}</span>],
              ['Unidades', r.unidades],
              ['Monto afianzado', <span key="afianzado" className="num">{q(r.monto_afianzado)}</span>],
              ['Vigencia de la fianza', `${fecha(r.vigencia_desde)} al ${fecha(r.vigencia_hasta)}`],
              r.monto_aprobado !== null ? ['Monto procedente', <span key="procedente" className="num">{q(r.monto_aprobado)}</span>] : null,
              r.monto_pagado ? ['Pagado a la marca', <span key="pagado" className="num">{q(r.monto_pagado)} el {fecha(r.fecha_pago)}</span>] : null,
              // El recobro al distribuidor es gestion de Fidelis: la marca no lo ve.
              r.monto_pagado && !usuario.esMarca ? ['Recuperado del afianzado', <span key="recuperado" className="num">{q(r.monto_recuperado)}</span>] : null,
              porRecuperar > 0 && !usuario.esMarca ? ['Pendiente de recuperar', <strong key="pendiente" className="num">{q(porRecuperar)}</strong>] : null,
            ]} />
            <p style={{ marginTop: '1rem' }}>{r.descripcion}</p>
            {r.resolucion && <Aviso tono="info" titulo="Resolución de Fidelis">{r.resolucion}</Aviso>}
          </Panel>

          <Panel titulo="Seguimiento" subtitulo="Lo más reciente primero" sinRelleno>
            {esLaMarca && abierto && (
              <div style={{ padding: '0.85rem 1.15rem', borderBottom: '1px solid var(--gris-150)' }}>
                <div className="row" style={{ alignItems: 'flex-start' }}>
                  <textarea className="control" style={{ flex: 1, minHeight: 64 }} placeholder="Escriba un mensaje para Fidelis"
                    value={nota} onChange={(e) => setNota(e.target.value)} aria-label="Mensaje" />
                  <button className="btn btn-secundario btn-sm" disabled={!nota.trim() || comentar.isPending}
                    onClick={() => comentar.mutateAsync({ comentario: nota }).then(() => setNota('')).catch(toast.error)}>
                    Agregar
                  </button>
                </div>
              </div>
            )}
            <ul className="linea" style={{ padding: '1rem 1.15rem' }}>
              {r.movimientos.map((m) => (
                <li key={m.id}>
                  <div className="row">
                    {m.estado_nuevo && <Estado mapa={ESTADO_RECLAMO} valor={m.estado_nuevo} />}
                    {m.interno && <span className="estado estado-neutro"><Lock size={12} aria-hidden="true" /> Interna</span>}
                    <span className="small muted">{fechaHora(m.created_at)} · {m.autor?.full_name || 'Sistema'}</span>
                  </div>
                  {m.comentario && <p className="small" style={{ marginTop: '0.25rem' }}>{m.comentario}</p>}
                  {m.monto ? <p className="small muted">{q(m.monto)}</p> : null}
                </li>
              ))}
            </ul>
          </Panel>
        </div>

        <div className="c-4 columna">
          <Panel titulo="Evidencia" sinRelleno>
            <ul className="tareas">
              {r.documentos.map((d) => (
                <li key={d.id}>
                  <button className="tarea" style={{ width: '100%', background: 'none', border: 0, cursor: 'pointer', textAlign: 'left' }}
                    onClick={() => abrirDocumento(d.file_path).catch(toast.error)}>
                    <ExternalLink size={16} aria-hidden="true" />
                    <span className="tarea-texto"><strong>{d.nombre_archivo}</strong><span className="sub">{fechaHora(d.created_at)}</span></span>
                  </button>
                </li>
              ))}
              {!r.documentos.length && <li className="al-dia">Sin documentos.</li>}
            </ul>
            {esLaMarca && abierto && (
              <div className="panel-pie">
                <label className="btn btn-secundario btn-sm" style={{ cursor: 'pointer' }}>
                  <FileUp size={16} aria-hidden="true" /> {subir.isPending ? 'Subiendo' : 'Agregar evidencia'}
                  <input type="file" className="sr-only" accept="application/pdf,image/png,image/jpeg"
                    onChange={(e) => { const a = e.target.files?.[0]; e.target.value = ''; if (a) subir.mutateAsync(a).then(() => toast.ok('Evidencia agregada.')).catch(toast.error); }} />
                </label>
              </div>
            )}
          </Panel>
          {!usuario.esMarca && (
            <Panel titulo="Afianzado" accion={<Link className="small" to={`/afianzados/${r.cliente_id}`}>Ver perfil</Link>}>
              <Datos items={[['Nombre', nombre(r.afianzado_nombre)], ['Código', r.afianzado_codigo]]} />
            </Panel>
          )}
        </div>
      </div>
    </div>
  );
}
